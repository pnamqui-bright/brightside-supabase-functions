#!/usr/bin/env python3
"""Manual HubSpot <-> Supabase Edge Function CLI (Python 3.9+; stdlib only)."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

VERSION = "1.0.0"
DEFAULT_URL = "https://supabase.brightsidebrandstudio.com"
MAX_RECORDS = 5
ENDPOINTS = {
    "pull": "hubspot-webhook",        # HubSpot -> Supabase, manually invoked
    "push": "hubspot-manual-push",    # Supabase -> HubSpot, manually invoked
}
OBJECT_TYPES = ("companies", "contacts")
SECRET_PATTERN = re.compile(r"^sb_secret_[A-Za-z0-9_-]{8,240}$")


class CliError(Exception):
    """An operator-facing CLI failure; never include secrets in the message."""


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    epilog = """Examples (all previews unless --apply is supplied):
  %(prog)s pull companies --limit 1 --env-file .env
  %(prog)s pull contacts --id 123456 --env-file .env
  %(prog)s push companies --id company-123 --env-file .env
  %(prog)s push contacts --id contact-123 --id contact-456 --json
  %(prog)s pull companies --cursor NEXT_CURSOR --limit 5
  %(prog)s push companies --id company-123 --apply --env-file .env
  %(prog)s push companies --id company-123 --apply --yes --env-file .env

Direction and IDs:
  pull = HubSpot -> Supabase; --id expects HubSpot numeric object IDs.
  push = Supabase -> HubSpot; --id expects Supabase external IDs.
  With no --id, the function previews one page (up to 5 records).
  --cursor is the opaque nextCursor from a previous preview.

Safe application:
  --apply first fetches and displays a fresh preview, then requires typing
  APPLY at the prompt before sending a second request with its previewHash.
  Applying requires explicit --id values; paged previews cannot be applied.
  --yes skips the interactive prompt (requires --apply and --id).
  No command runs automatically or on a schedule. Neither endpoint creates
  new records; contacts without matching company associations are skipped.

Authentication:
  Reads SUPABASE_SECRET_KEY from the process environment, or from --env-file
  if explicitly supplied. --env-file takes precedence. Uses the apikey
  header, NEVER Authorization: Bearer. Never pass secrets on the command line.
  Standard self-hosted Supabase requires FUNCTIONS_VERIFY_JWT=false to accept
  opaque API keys; the functions still verify their apikey independently.
"""
    parser = argparse.ArgumentParser(
        description=(
            "Invoke the two manually triggered Brightside Supabase/HubSpot sync "
            "Edge Functions. PREVIEW is the default; no CRM writes without --apply."
        ),
        epilog=epilog,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("direction", choices=tuple(ENDPOINTS),
                        help="pull: HubSpot to Supabase; push: Supabase to HubSpot")
    parser.add_argument("object_type", choices=OBJECT_TYPES, metavar="{companies,contacts}",
                        help="CRM object type to synchronize")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--id", dest="ids", action="append", metavar="RECORD_ID",
                       help="select exact record ID (repeat up to 5 times); required for --apply")
    group.add_argument("--cursor", metavar="OPAQUE_CURSOR",
                       help="preview next page using nextCursor from prior response")
    parser.add_argument("--limit", metavar="N", type=int, default=5,
                        help="page size, 1-5 records (default: 5; ignored when --id is used)")
    parser.add_argument("--apply", action="store_true",
                        help="preview first, then apply approved changes using previewHash and confirm=APPLY")
    parser.add_argument("--yes", action="store_true",
                        help="skip interactive APPLY prompt; requires --apply and explicit --id")
    parser.add_argument("--show-skipped", action="store_true",
                        help="include each skipped field and skip reason in human-readable preview")
    parser.add_argument("--json", action="store_true",
                        help="print unabridged JSON instead of human-readable output; --apply requires --yes")
    parser.add_argument("--env-file", metavar="PATH", type=Path,
                        help="read SUPABASE_SECRET_KEY from this .env file (overrides environment)")
    parser.add_argument("--url", default=DEFAULT_URL, metavar="BASE_URL",
                        help=f"Supabase public base URL (default: {DEFAULT_URL})")
    parser.add_argument("--timeout", type=float, default=120.0, metavar="SECONDS",
                        help="HTTP request timeout per invocation in seconds (default: 120)")
    parser.add_argument("--allow-http", action="store_true",
                        help="permit unencrypted http:// URLs only on localhost (testing only)")
    parser.add_argument("--version", action="version", version=f"hubspot-sync {VERSION}")
    args = parser.parse_args(argv)
    if not 1 <= args.limit <= MAX_RECORDS:
        parser.error("--limit must be between 1 and 5")
    if not 0 < args.timeout <= 600:
        parser.error("--timeout must be between 0 and 600 seconds")
    if args.ids and (len(args.ids) > MAX_RECORDS or
                     len(set(args.ids)) != len(args.ids) or
                     any(not value.strip() or len(value) > 200 for value in args.ids)):
        parser.error("--id must provide 1-5 unique nonempty IDs, each at most 200 characters")
    if args.direction == "pull" and args.ids and any(not id_.isdigit() for id_ in args.ids):
        parser.error("pull --id expects numeric HubSpot IDs (e.g. 123456)")
    if args.cursor is not None and not args.cursor.strip():
        parser.error("--cursor cannot be empty")
    if args.apply and not args.ids:
        parser.error("--apply requires at least one explicit --id (paged selections are preview-only)")
    if args.yes and not args.apply:
        parser.error("--yes requires --apply")
    if args.json and args.apply and not args.yes:
        parser.error("--json with --apply requires --yes so the preview is not hidden by JSON mode")
    return args


def load_key(env_file: Path | None) -> str:
    if env_file is not None:
        try:
            data = env_file.read_text(encoding="utf-8")
        except OSError as exc:
            raise CliError(f"Could not read --env-file {env_file}: {exc.strerror or 'I/O error'}") from None
        value = ""
        for line in data.splitlines():
            line = line.strip()
            if line.startswith("export "):
                line = line[7:].lstrip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            name, raw = line.split("=", 1)
            if name.strip() != "SUPABASE_SECRET_KEY":
                continue
            value = raw.strip()
            if len(value) >= 2 and value[0] in "\"'" and value[-1] == value[0]:
                value = value[1:-1]
            break
    else:
        value = os.environ.get("SUPABASE_SECRET_KEY", "").strip()
    if not value:
        raise CliError("SUPABASE_SECRET_KEY not found. Set it in the environment or pass --env-file /path/to/.env")
    if not SECRET_PATTERN.fullmatch(value):
        raise CliError("SUPABASE_SECRET_KEY must be an opaque sb_secret_... key; legacy service-role JWTs are unsupported")
    return value


def function_url(base: str, direction: str, allow_http: bool) -> str:
    parts = urllib.parse.urlsplit(base)
    if parts.scheme != "https":
        host = (parts.hostname or "").lower()
        if not (allow_http and parts.scheme == "http" and host in {"127.0.0.1", "localhost", "::1"}):
            raise CliError("--url must start with https:// (or use --allow-http for localhost tests only)")
    if not parts.netloc or parts.username or parts.password or parts.query or parts.fragment or parts.path not in {"", "/"}:
        raise CliError("--url must be a plain Supabase base URL without credentials, path, query or fragment")
    endpoint = ENDPOINTS[direction]
    return base.rstrip("/") + "/functions/v1/" + endpoint


def post(url: str, key: str, body: dict, timeout: float) -> dict:
    encoded = json.dumps(body, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    request = urllib.request.Request(url, data=encoded, method="POST", headers={
        "apikey": key,
        "Content-Type": "application/json",
        "Accept": "application/json",
        "User-Agent": "BrightsideHubSpotSyncCLI/" + VERSION,
    })
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            status = response.status
            raw = response.read(2_000_001)
    except urllib.error.HTTPError as exc:
        raw = exc.read(1_000_001)
        reason = ""
        try:
            detail = json.loads(raw.decode("utf-8"))
            if isinstance(detail, dict):
                reason = str(detail.get("error") or detail.get("message") or "")
        except (UnicodeError, ValueError):
            pass
        if exc.code == 401:
            reason = "Unauthorized. Check SUPABASE_SECRET_KEY, apikey header and FUNCTIONS_VERIFY_JWT=false."
        if exc.code == 404:
            reason = "Function not found. Check --url and whether both functions are mounted."
        if exc.code == 409:
            reason = "Preview changed; re-run the command for a fresh preview."
        if exc.code in (502, 503):
            reason = "Gateway or Edge Runtime unavailable; check Docker services and function logs."
        reason = reason.replace(key, "[REDACTED]")
        raise CliError(f"HTTP {exc.code}: {reason[:500] or 'request failed'}") from None
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        safe_message = str(exc.reason if isinstance(exc, urllib.error.URLError) else exc)
        raise CliError("Network error: " + safe_message.replace(key, "[REDACTED]")[:500]) from None
    if len(raw) > 2_000_000:
        raise CliError("Response exceeded 2 MB; restrict the request with --id or --limit")
    try:
        result = json.loads(raw.decode("utf-8"))
    except (UnicodeError, ValueError):
        raise CliError(f"HTTP {status} returned non-JSON data; check the Edge Function runtime") from None
    if not isinstance(result, dict):
        raise CliError("Function returned an unexpected JSON response (expected an object)")
    if status not in (200, 207):
        raise CliError(f"Unexpected HTTP {status} response")
    return result


def pretty(value: object) -> str:
    # Represent line breaks visibly so diffs don't accidentally hide content.
    return repr(str(value or ""))


def render_preview(result: dict, show_skipped: bool) -> None:
    summary = result.get("summary") or {}
    print("\nPREVIEW | {direction} {entity}".format(
        direction=str(result.get("direction", "")).upper(),
        entity=result.get("objectType", "?"),
    ))
    print("  Matched: {matched}  Skipped: {skipped}  Errors: {errors}  Proposed field updates: {updates}".format(
        matched=summary.get("matched", "?"), skipped=summary.get("skipped", "?"),
        errors=summary.get("errors", "?"), updates=summary.get("proposedFieldUpdates", "?"),
    ))
    for record in result.get("records") or []:
        if not isinstance(record, dict):
            continue
        status = record.get("status", "unknown")
        print("\n  Record {id} [{status}]".format(id=record.get("id", "?"), status=status))
        if record.get("reason"):
            print("    Reason: " + str(record["reason"]))
        for change in record.get("changes") or []:
            if not isinstance(change, dict):
                continue
            if change.get("action") != "update" and not show_skipped:
                continue
            operation = "UPDATE" if change.get("action") == "update" else "SKIP  "
            print("    {verb} {property}: {before} -> {after} ({reason})".format(
                verb=operation, property=change.get("property", "?"),
                before=pretty(change.get("before")), after=pretty(change.get("after")),
                reason=change.get("reason", "?"),
            ))
    if result.get("nextCursor"):
        print("\n  Next page: --cursor " + str(result["nextCursor"]))
    print("\n  Preview hash: " + str(result.get("previewHash", "missing")))


def render_application(result: dict) -> bool:
    print("\nAPPLY RESULTS")
    applied = result.get("applied") or []
    failure = False
    for record in applied:
        status = str(record.get("status", "unknown"))
        count = record.get("fieldsUpdated", 0)
        print(f"  {record.get('id', '?')}: {status} ({count} field updates)")
        if record.get("error"):
            print(f"    Error: {record['error']}")
        if status == "error":
            failure = True
    if result.get("error"):
        print("  Error: " + str(result["error"]))
        failure = True
    return not failure


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    url = function_url(args.url, args.direction, args.allow_http)
    key = load_key(args.env_file)
    body: dict = {"action": "preview", "objectType": args.object_type}
    if args.ids:
        body["ids"] = args.ids
    else:
        body["limit"] = args.limit
        if args.cursor:
            body["cursor"] = args.cursor
    preview = post(url, key, body, args.timeout)
    if preview.get("error"):
        raise CliError("Preview error: " + str(preview["error"]).replace(key, "[REDACTED]")[:500])
    if preview.get("action") != "preview" or preview.get("objectType") != args.object_type or preview.get("direction") != args.direction:
        raise CliError("Unexpected preview response (action, direction or objectType mismatch)")
    if not args.apply:
        if args.json:
            print(json.dumps(preview, indent=2, ensure_ascii=False))
        else:
            render_preview(preview, args.show_skipped)
        return 0 if not (preview.get("summary") or {}).get("errors") else 1

    # Application is deliberately impossible without explicit IDs and a fresh preview.
    records = preview.get("records")
    digest = preview.get("previewHash")
    if not isinstance(records, list) or {str(x.get("id")) for x in records if isinstance(x, dict)} != set(args.ids):
        raise CliError("Preview did not return exactly the requested IDs; refusing to apply")
    if not isinstance(digest, str) or not re.fullmatch(r"[a-f0-9]{64}", digest):
        raise CliError("Preview did not return a valid previewHash; refusing to apply")
    summary = preview.get("summary") or {}
    if summary.get("errors") or any(x.get("status") == "error" for x in records):
        raise CliError("Preview contains errors; refusing to apply")
    proposed = sum(1 for record in records for field in (record.get("changes") or []) if field.get("action") == "update")
    if proposed == 0:
        if args.json:
            print(json.dumps({"preview": preview, "applied": False, "reason": "no_changes"}, indent=2, ensure_ascii=False))
        else:
            render_preview(preview, args.show_skipped)
            print("\nNo field updates are proposed. Nothing to apply.")
        return 0
    if not args.yes:
        render_preview(preview, args.show_skipped)
        if not sys.stdin.isatty():
            raise CliError("Non-interactive apply needs explicit --yes (and --id)")
        destination = "Supabase" if args.direction == "pull" else "HubSpot"
        print(f"\nAbout to change {proposed} field(s) in {destination} across up to {len(args.ids)} records.")
        try:
            answer = input("Type APPLY to proceed (anything else cancels): ")
        except EOFError:
            answer = ""
        if answer != "APPLY":
            print("Cancelled; no apply request sent.")
            return 0
    elif not args.json:
        render_preview(preview, args.show_skipped)
        print("\n--yes supplied: applying without interactive confirmation.")

    result = post(url, key, {
        "action": "apply",
        "objectType": args.object_type,
        "ids": args.ids,
        "previewHash": digest,
        "confirm": "APPLY",
    }, args.timeout)
    if args.json:
        print(json.dumps({"preview": preview, "result": result}, indent=2, ensure_ascii=False))
    else:
        render_application(result)
    applied = result.get("applied")
    good = isinstance(applied, list) and len(applied) == len(args.ids) and not result.get("error") and all(
        isinstance(item, dict) and item.get("status") in {"applied", "skipped"} for item in applied
    )
    return 0 if good else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except CliError as exc:
        print("hubspot-sync: " + str(exc), file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("\nCancelled.", file=sys.stderr)
        sys.exit(130)
