"""CLI tests use a localhost mock, never live Supabase or HubSpot services."""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "hubspot_sync.py"
FAKE_KEY = "sb_secret_test_fake_0123456789abcdef"


def planned(action: str, direction: str, object_type: str, ids: list[str]) -> dict:
    return {
        "action": action,
        "direction": direction,
        "objectType": object_type,
        "records": [
            {
                "id": ident,
                "localId": "local-1",
                "status": "ready",
                "changes": [{
                    "property": "name", "before": "", "after": "Example Company",
                    "reason": "fill_empty_destination", "action": "update",
                }],
            } for ident in ids
        ],
        "summary": {
            "records": len(ids), "matched": len(ids), "skipped": 0, "errors": 0,
            "proposedFieldUpdates": len(ids),
        },
        "previewHash": "a" * 64,
        "nextCursor": "after-1" if ids == ["111"] else None,
    }


class ApiServer:
    def __init__(self) -> None:
        self.calls: list[dict] = []
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self) -> None:
                length = int(self.headers["Content-Length"])
                body = json.loads(self.rfile.read(length))
                outer.calls.append({
                    "path": self.path,
                    "headers": {key.lower(): value for key, value in self.headers.items()},
                    "body": body,
                })
                if self.headers.get("apikey") != FAKE_KEY:
                    self.send_json(401, {"error": "Unauthorized"})
                    return
                direction = "pull" if self.path.endswith("hubspot-webhook") else "push"
                ids = body.get("ids", ["111"])
                response = planned(body["action"], direction, body["objectType"], ids)
                if body["action"] == "apply":
                    response["applied"] = [
                        {"id": item, "fieldsUpdated": 1, "status": "applied"} for item in ids
                    ]
                    if body.get("previewHash") != "a" * 64 or body.get("confirm") != "APPLY":
                        self.send_json(409, {"error": "Preview changed"})
                        return
                self.send_json(200, response)

            def send_json(self, status: int, value: dict) -> None:
                body = json.dumps(value).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_args: object) -> None:
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.url = f"http://127.0.0.1:{self.server.server_port}"

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_args: object):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)


def invoke(*args: str, env_key: str | None = FAKE_KEY) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    env.pop("SUPABASE_SECRET_KEY", None)
    if env_key is not None:
        env["SUPABASE_SECRET_KEY"] = env_key
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args], env=env, input="", text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10,
    )


class CliTests(unittest.TestCase):
    def test_help_no_auth_needed(self):
        result = invoke("--help", env_key=None)
        self.assertEqual(result.returncode, 0, result.stderr)
        for term in ("--id", "--limit", "--cursor", "--apply", "--yes", "--env-file", "--json", "--timeout"):
            self.assertIn(term, result.stdout)

    def test_version(self):
        result = invoke("--version", env_key=None)
        self.assertEqual(result.returncode, 0)
        self.assertIn("1.0.0", result.stdout)

    def test_default_previews_pull_without_writes(self):
        with ApiServer() as api:
            result = invoke("pull", "companies", "--limit", "1", "--url", api.url, "--allow-http")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(api.calls), 1)
            self.assertEqual(api.calls[0]["path"], "/functions/v1/hubspot-webhook")
            self.assertEqual(api.calls[0]["body"], {"action": "preview", "objectType": "companies", "limit": 1})
            self.assertEqual(api.calls[0]["headers"]["apikey"], FAKE_KEY)
            self.assertNotIn("authorization", api.calls[0]["headers"])
            self.assertIn("PREVIEW", result.stdout)
            self.assertIn("after-1", result.stdout)
            self.assertNotIn(FAKE_KEY, result.stdout + result.stderr)

    def test_push_contact_multiple_ids_returns_json(self):
        with ApiServer() as api:
            result = invoke("push", "contacts", "--id", "c1", "--id", "c2", "--json",
                            "--url", api.url, "--allow-http")
            self.assertEqual(result.returncode, 0, result.stderr)
            response = json.loads(result.stdout)
            self.assertEqual(response["direction"], "push")
            self.assertEqual(api.calls[0]["path"], "/functions/v1/hubspot-manual-push")
            self.assertEqual(api.calls[0]["body"]["ids"], ["c1", "c2"])

    def test_preview_cursor_and_show_skipped_flag(self):
        with ApiServer() as api:
            result = invoke("pull", "companies", "--cursor", "after-1", "--limit", "2",
                            "--show-skipped", "--url", api.url, "--allow-http")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(api.calls[0]["body"]["cursor"], "after-1")

    def test_apply_with_yes_sends_hash_and_confirm(self):
        with ApiServer() as api:
            result = invoke("pull", "companies", "--id", "111", "--apply", "--yes",
                            "--url", api.url, "--allow-http")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(api.calls), 2)
            self.assertEqual([c["body"]["action"] for c in api.calls], ["preview", "apply"])
            self.assertEqual(api.calls[1]["body"], {
                "action": "apply", "objectType": "companies", "ids": ["111"],
                "previewHash": "a" * 64, "confirm": "APPLY",
            })
            self.assertIn("APPLY RESULTS", result.stdout)

    def test_apply_json_returns_both_exchanges(self):
        with ApiServer() as api:
            result = invoke("push", "companies", "--id", "example-1", "--apply", "--yes", "--json",
                            "--url", api.url, "--allow-http")
            self.assertEqual(result.returncode, 0, result.stderr)
            value = json.loads(result.stdout)
            self.assertEqual(value["preview"]["action"], "preview")
            self.assertEqual(value["result"]["action"], "apply")

    def test_apply_requires_ids(self):
        result = invoke("pull", "companies", "--apply")
        self.assertEqual(result.returncode, 2)
        self.assertIn("requires at least one explicit --id", result.stderr)

    def test_json_apply_requires_yes(self):
        result = invoke("push", "companies", "--id", "abc", "--json", "--apply")
        self.assertEqual(result.returncode, 2)
        self.assertIn("--json with --apply requires --yes", result.stderr)

    def test_interactive_apply_without_tty_never_sends_apply(self):
        with ApiServer() as api:
            result = invoke("pull", "companies", "--id", "111", "--apply",
                            "--url", api.url, "--allow-http")
            self.assertEqual(result.returncode, 1)
            self.assertEqual(len(api.calls), 1)
            self.assertEqual(api.calls[0]["body"]["action"], "preview")
            self.assertIn("Non-interactive", result.stderr)

    def test_rejects_bad_parameters_and_http_without_allow(self):
        invalid = [
            ("pull", "companies", "--id", "abc"),
            ("push", "companies", "--limit", "10"),
            ("push", "companies", "--yes"),
            ("push", "companies", "--id", "abc", "--cursor", "xxx"),
        ]
        for args in invalid:
            with self.subTest(args=args):
                result = invoke(*args)
                self.assertEqual(result.returncode, 2)
        result = invoke("push", "companies", "--url", "http://127.0.0.1:1234")
        self.assertEqual(result.returncode, 1)
        self.assertIn("https://", result.stderr)

    def test_explicit_env_file_precedence(self):
        with tempfile.TemporaryDirectory() as tmp, ApiServer() as api:
            path = Path(tmp) / ".env"
            path.write_text(f'export SUPABASE_SECRET_KEY="{FAKE_KEY}"\n', encoding="utf-8")
            result = invoke("pull", "companies", "--limit", "1", "--env-file", str(path),
                            "--url", api.url, "--allow-http", env_key="sb_secret_wrong_secret_abcdefgh12345")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(api.calls[0]["headers"]["apikey"], FAKE_KEY)

    def test_missing_key_fails_before_network(self):
        result = invoke("pull", "companies", env_key=None)
        self.assertEqual(result.returncode, 1)
        self.assertIn("SUPABASE_SECRET_KEY not found", result.stderr)


if __name__ == "__main__":
    unittest.main()
