#!/usr/bin/env python3
"""Manual bulk-only HubSpot <-> Supabase sync. Python 3.9+, standard library only.

The CLI owns full dataset traversal, the immutable ID-only plan, retries and progress.
No targeted/single-ID user workflow is exposed.
"""
from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import random
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

VERSION = "2.0.0"
DEFAULT_URL = "https://supabase.brightsidebrandstudio.com"
SECRET_PATTERN = re.compile(r"^sb_secret_[A-Za-z0-9_-]{8,240}$")
PLAN_SCHEMA = 1
ORDER = (("companies", "pull"), ("companies", "push"), ("contacts", "pull"), ("contacts", "push"))
SUCCESS = {"created", "applied", "already_synchronized", "skipped", "conflict"}


class CliError(Exception):
    """Operator-facing exception (do not include credentials)."""


class HttpFailure(CliError):
    def __init__(self, code: int, message: str, retry_after: float = 0):
        super().__init__(f"HTTP {code}: {message}")
        self.code = code
        self.retry_after = retry_after


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="hubspot-sync",
        description="Manual BULK-ONLY HubSpot/Supabase reconciliation: plan, apply, resume.",
        epilog="Examples:\n  hubspot-sync plan --env-file ../supabase/.env\n"
               "  hubspot-sync apply --yes --env-file ../supabase/.env\n"
               "  hubspot-sync resume --env-file ../supabase/.env\n"
               "  hubspot-sync apply --force=pull --env-file ../supabase/.env\n"
               "No record-ID option exists: commands always process the full eligible dataset.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("command", choices=("plan", "apply", "resume"))
    parser.add_argument("--plan-file", type=Path, default=Path("plan.json"))
    parser.add_argument("--checkpoint-file", type=Path, default=Path("checkpoint.json"))
    parser.add_argument("--report-file", type=Path, default=Path("sync-report.json"))
    parser.add_argument("--batch-size", type=int, default=25,
                        help="executor batch size, 1..100 (start at 25; scale up after profiling)")
    parser.add_argument("--force", choices=("pull", "push"),
                        help="explicit direction to override ALL reported record conflicts")
    parser.add_argument("--yes", action="store_true", help="confirm all bulk writes without an interactive prompt")
    parser.add_argument("--json", action="store_true", help="output machine-readable summary")
    parser.add_argument("--env-file", type=Path)
    parser.add_argument("--url", default=DEFAULT_URL)
    parser.add_argument("--timeout", type=float, default=120)
    parser.add_argument("--allow-http", action="store_true", help="localhost tests only")
    parser.add_argument("--version", action="version", version=f"hubspot-sync {VERSION}")
    args = parser.parse_args(argv)
    if not 1 <= args.batch_size <= 100: parser.error("--batch-size must be between 1 and 100")
    if not 0 < args.timeout <= 600: parser.error("--timeout must be between 0 and 600")
    if args.command == "plan" and (args.yes or args.force): parser.error("plan is read-only; --force and --yes are apply-only")
    return args


def load_key(env_file: Path | None) -> str:
    if env_file is None:
        key = os.environ.get("SUPABASE_SECRET_KEY", "").strip()
    else:
        try: lines = env_file.read_text(encoding="utf-8").splitlines()
        except OSError as exc: raise CliError(f"Could not read {env_file}: {exc.strerror or 'I/O error'}") from None
        key = ""
        for line in lines:
            line = line.strip().removeprefix("export ")
            if line.startswith("SUPABASE_SECRET_KEY="):
                key = line.split("=", 1)[1].strip().strip('"\'')
                break
    if not key: raise CliError("SUPABASE_SECRET_KEY not found (environment or --env-file)")
    if not SECRET_PATTERN.fullmatch(key): raise CliError("SUPABASE_SECRET_KEY must use the sb_secret_... format")
    return key


def base_url(url: str, allow_http: bool) -> str:
    parts = urllib.parse.urlsplit(url)
    if parts.scheme != "https" and not (allow_http and parts.scheme == "http" and parts.hostname in ("127.0.0.1", "localhost", "::1")):
        raise CliError("--url must be HTTPS (HTTP only via --allow-http on localhost)")
    if not parts.netloc or parts.username or parts.password or parts.path not in ("", "/") or parts.query or parts.fragment:
        raise CliError("--url must be a plain base URL without path, query, or credentials")
    return url.rstrip("/")


def post(base: str, endpoint: str, key: str, body: dict, timeout: float) -> dict:
    url = base + "/functions/v1/" + endpoint
    request = urllib.request.Request(url, data=json.dumps(body, separators=(",", ":")).encode(), method="POST", headers={
        "apikey": key, "Content-Type": "application/json", "Accept": "application/json",
        "User-Agent": "BrightsideBulkSync/" + VERSION,
    })
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read(8_000_001)
    except urllib.error.HTTPError as exc:
        raw = exc.read(100_000)
        message = "request failed"
        try:
            parsed = json.loads(raw.decode("utf-8"))
            message = str(parsed.get("error") or parsed.get("message") or message)
        except (UnicodeError, ValueError, AttributeError): pass
        retry = 0.0
        try: retry = max(0, float(exc.headers.get("Retry-After", "0")))
        except ValueError: pass
        raise HttpFailure(exc.code, message.replace(key, "[REDACTED]")[:250], retry) from None
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise CliError("Network error: " + str(exc).replace(key, "[REDACTED]")[:300]) from None
    if len(raw) > 8_000_000: raise CliError("Edge response too large; lower batch/page size")
    try: result = json.loads(raw.decode("utf-8"))
    except (UnicodeError, ValueError): raise CliError("Edge response is not JSON") from None
    if not isinstance(result, dict): raise CliError("Edge response must be an object")
    return result


def safe_post(base: str, endpoint: str, key: str, body: dict, timeout: float) -> dict:
    for attempt in range(5):
        try: return post(base, endpoint, key, body, timeout)
        except (HttpFailure, CliError) as exc:
            retryable = (isinstance(exc, HttpFailure) and (exc.code == 429 or exc.code >= 500)) or (not isinstance(exc, HttpFailure) and str(exc).startswith("Network error:"))
            if not retryable or attempt == 4: raise
            delay = exc.retry_after if isinstance(exc, HttpFailure) else 0
            time.sleep(max(delay, min(30, 2 ** attempt) + random.uniform(0, 0.5)))
    raise CliError("retry limit exceeded")


def atomic_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    try:
        with tmp.open("w", encoding="utf-8") as f:
            json.dump(value, f, indent=2, ensure_ascii=False)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        if tmp.exists(): tmp.unlink()


def read_json(path: Path) -> dict:
    try: data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc: raise CliError(f"Cannot read {path}: {type(exc).__name__}") from None
    if not isinstance(data, dict): raise CliError(f"{path} must contain an object")
    return data


def identity(op: dict) -> str:
    return ":".join((op["entity"], op["direction"], op["id"]))


def plan_hash(plan: dict) -> str:
    signed = {key: plan[key] for key in ("schemaVersion", "complete", "operations", "conflicts", "skipped")}
    return hashlib.sha256(json.dumps(signed, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def do_plan(args: argparse.Namespace, base: str, key: str) -> int:
    all_records: list[dict] = []
    operations: list[dict] = []
    conflicts: list[dict] = []
    skipped: list[dict] = []
    seen_hs: set[tuple[str, str]] = set()
    seen_local: set[tuple[str, str]] = set()
    local_to_remote: dict[tuple[str, str], str] = {}
    duplicates: set[tuple[str, str]] = set()
    new_natural_to_remote: dict[tuple[str, str], tuple[str, str]] = {}
    scanned = Counter()
    for entity in ("companies", "contacts"):
        cursor = None
        previous = set()
        while True:
            body = {"objectType": entity, "source": "hubspot", "limit": 50}
            if cursor: body["cursor"] = cursor
            page = safe_post(base, "hubspot-bulk-plan", key, body, args.timeout)
            if page.get("objectType") != entity or page.get("source") != "hubspot" or not isinstance(page.get("records"), list):
                raise CliError("Planner returned invalid HubSpot page; no plan saved")
            for record in page["records"]:
                remote = str(record.get("hubspotId") or "")
                local = str(record.get("supabaseId") or "")
                if not remote: raise CliError("Planner page has missing HubSpot ID")
                if (entity, remote) in seen_hs: raise CliError("HubSpot record repeated across pages")
                seen_hs.add((entity, remote))
                if local:
                    link = (entity, local)
                    seen_local.add(link)
                    prior = local_to_remote.setdefault(link, remote)
                    if prior != remote: duplicates.add(link)
                match_key = str(record.get("matchKey") or "")
                if match_key and local:
                    k = (entity, match_key)
                    prior = new_natural_to_remote.setdefault(k, (remote, local))
                    if prior[0] != remote:
                        duplicates.add((entity, prior[1]))
                        duplicates.add((entity, local))
                if record.get("status") == "conflict":
                    conflicts.append({"entity": entity, "hubspotId": remote, "supabaseId": local, "reason": record.get("reason", "conflict")})
                elif record.get("status") == "skipped":
                    skipped.append({"entity": entity, "hubspotId": remote, "supabaseId": local, "reason": record.get("reason", "skipped")})
                elif record.get("status") == "work":
                    for op in record.get("operations") or []:
                        if not isinstance(op, dict) or op.get("entity") != entity or op.get("direction") not in ("pull", "push") or not isinstance(op.get("id"), str) or not op["id"]:
                            raise CliError("Planner returned invalid operation")
                        operations.append({"entity": entity, "id": op["id"], "direction": op["direction"]})
                elif record.get("status") != "equal":
                    raise CliError("Planner returned unknown record status")
                all_records.append(record)
                scanned[entity] += 1
            next_cursor = page.get("nextCursor")
            if not next_cursor: break
            if next_cursor == cursor or next_cursor in previous: raise CliError("Planner cursor repeated")
            previous.add(next_cursor)
            cursor = next_cursor
        # Enumerate ALL local IDs as well; unmatched ones are reported, never created in HubSpot.
        cursor = None
        previous = set()
        while True:
            body = {"objectType": entity, "source": "supabase", "limit": 500}
            if cursor: body["cursor"] = cursor
            page = safe_post(base, "hubspot-bulk-plan", key, body, args.timeout)
            if page.get("objectType") != entity or page.get("source") != "supabase" or not isinstance(page.get("ids"), list):
                raise CliError("Planner returned invalid Supabase page")
            for local in page["ids"]:
                scanned["supabase_" + entity] += 1
                if (entity, str(local)) not in seen_local:
                    skipped.append({"entity": entity, "supabaseId": str(local), "reason": "unmatched_outbound_no_creation"})
            next_cursor = page.get("nextCursor")
            if not next_cursor: break
            if next_cursor == cursor or next_cursor in previous: raise CliError("Supabase cursor repeated")
            previous.add(next_cursor)
            cursor = next_cursor
    if duplicates:
        operations = [op for op in operations if (op["entity"], op["id"] if op["direction"] == "push" else next((r.get("supabaseId", "") for r in all_records if r.get("entity") == op["entity"] and r.get("hubspotId") == op["id"]), "")) not in duplicates]
        conflicts = [c for c in conflicts if (c["entity"], c.get("supabaseId", "")) not in duplicates]
        for entity, local in sorted(duplicates):
            remote = local_to_remote.get((entity, local), "")
            conflicts.append({"entity": entity, "supabaseId": local, "hubspotId": remote,
                              "reason": "duplicate_hubspot_match_global_scan"})
    deduped = {identity(op): op for op in operations}
    ordered = [op for entity, direction in ORDER for op in deduped.values() if op["entity"] == entity and op["direction"] == direction]
    plan = {
        "schemaVersion": PLAN_SCHEMA, "complete": True,
        "createdAt": datetime.now(timezone.utc).isoformat(), "operations": ordered,
        "conflicts": conflicts, "skipped": skipped,
        "summary": dict(scanned) | {"operations": len(ordered), "conflicts": len(conflicts), "skipped": len(skipped)},
    }
    plan["planHash"] = plan_hash(plan)
    atomic_json(args.plan_file, plan)
    result = {"planFile": str(args.plan_file), "planHash": plan["planHash"], **plan["summary"]}
    if args.json: print(json.dumps(result, indent=2))
    else:
        print(f"BULK PLAN COMPLETE: {args.plan_file}\n  HubSpot companies: {scanned['companies']}  contacts: {scanned['contacts']}")
        print(f"  Supabase companies: {scanned['supabase_companies']}  contacts: {scanned['supabase_contacts']}")
        print(f"  Eligible operations: {len(ordered)}  conflicts: {len(conflicts)}  skipped: {len(skipped)}")
        print("  No records were modified. Inspect plan.json for conflict details.")
    return 0


def confirm_apply(args: argparse.Namespace, count: int, conflicts: int) -> None:
    if args.yes: return
    if not sys.stdin.isatty(): raise CliError("Interactive confirmation required; use --yes in non-interactive environments")
    print(f"About to process {count} bulk operations. {conflicts} conflicts are reported.")
    if args.force: print(f"DANGER: --force={args.force} deliberately overrides {conflicts} conflicting records in that direction.")
    try: answer = input("Type APPLY to execute the bulk worklist: ")
    except EOFError: answer = ""
    if answer != "APPLY": raise CliError("Bulk apply cancelled")


def do_apply(args: argparse.Namespace, base: str, key: str) -> int:
    plan = read_json(args.plan_file)
    if plan.get("schemaVersion") != PLAN_SCHEMA or plan.get("complete") is not True or plan.get("planHash") != plan_hash(plan):
        raise CliError("Plan incomplete, unsupported, or modified; refusing bulk writes")
    for op in plan["operations"]:
        if not isinstance(op, dict) or op.get("entity") not in ("companies", "contacts") or op.get("direction") not in ("pull", "push") or not isinstance(op.get("id"), str) or not op["id"]:
            raise CliError("Invalid executable operation in plan")
    work = [{**op, "force": False} for op in plan["operations"]]
    if args.force:
        for conflict in plan["conflicts"]:
            if conflict.get("entity") not in ("companies", "contacts"): continue
            ident = conflict.get("hubspotId" if args.force == "pull" else "supabaseId")
            if isinstance(ident, str) and ident:
                work.append({"entity": conflict["entity"], "id": ident, "direction": args.force, "force": True})
    seen: set[str] = set()
    unique = []
    for op in work:
        key_id = identity(op)
        if key_id not in seen:
            unique.append(op)
            seen.add(key_id)
    work = [op for entity, direction in ORDER for op in unique if op["entity"] == entity and op["direction"] == direction]
    if args.command == "resume" and not args.checkpoint_file.exists(): raise CliError("No checkpoint found; use apply first")
    cp = read_json(args.checkpoint_file) if args.checkpoint_file.exists() else {
        "schemaVersion": PLAN_SCHEMA, "planHash": plan["planHash"], "forceDirection": args.force,
        "completed": [], "outcomes": {},
    }
    if cp.get("planHash") != plan["planHash"] or cp.get("forceDirection") != args.force:
        raise CliError("Checkpoint plan/direction mismatch; use a different --checkpoint-file")
    completed = set(cp["completed"])
    remaining = [op for op in work if identity(op) not in completed]
    confirm_apply(args, len(remaining), len(plan["conflicts"]))
    if not args.json: print(f"BULK APPLY: {len(remaining)} remaining operations across four ordered groups")
    for entity, direction in ORDER:
        for forced in (False, True):
            group = [op for op in remaining if op["entity"] == entity and op["direction"] == direction and op["force"] == forced]
            for at in range(0, len(group), args.batch_size):
                batch = group[at:at + args.batch_size]
                ids = [op["id"] for op in batch]
                body = {"objectType": entity, "direction": direction, "ids": ids,
                        "confirm": "FORCE_" + direction.upper() if forced else "APPLY"}
                if forced: body["force"] = True
                try:
                    response = safe_post(base, "hubspot-bulk-execute", key, body, args.timeout)
                    records = response.get("results")
                    if response.get("objectType") != entity or response.get("direction") != direction or not isinstance(records, list):
                        raise CliError("Executor response does not match requested group")
                    by_id = {str(r.get("id")): r for r in records if isinstance(r, dict)}
                    if set(by_id) != set(ids) or len(records) != len(ids):
                        raise CliError("Executor returned incomplete or duplicated per-record outcomes")
                except CliError as exc:
                    # No reliable per-record acknowledgement: nothing in this batch is marked complete.
                    if not args.json: print(f"  uncertain {entity}/{direction} batch: {exc}", file=sys.stderr)
                    for op in batch: cp["outcomes"][identity(op)] = {"status": "failed", "reason": "uncertain_batch"}
                    atomic_json(args.checkpoint_file, cp)
                    continue
                for op in batch:
                    k = identity(op)
                    result = by_id[op["id"]]
                    cp["outcomes"][k] = result
                    if result.get("status") in SUCCESS: completed.add(k)
                cp["completed"] = sorted(completed)
                atomic_json(args.checkpoint_file, cp)
                if not args.json: print(f"  {entity}/{direction}{' FORCE' if forced else ''}: {len(completed)} / {len(work)} accounted")
    outcomes = list(cp["outcomes"].values())
    counts = Counter(str(r.get("status", "unknown")) for r in outcomes)
    new_conflicts = [{"operation": op, "result": cp["outcomes"].get(identity(op))} for op in work if cp["outcomes"].get(identity(op), {}).get("status") == "conflict"]
    report = {"planHash": plan["planHash"], "plannedConflicts": plan["conflicts"], "executionConflicts": new_conflicts,
              "skipped": plan["skipped"], "counts": dict(counts), "pending": len(work) - len(completed),
              "failed": [{"operation": op, "result": cp["outcomes"].get(identity(op))} for op in work if identity(op) not in completed],
              "updatedAt": datetime.now(timezone.utc).isoformat()}
    atomic_json(args.report_file, report)
    if args.json: print(json.dumps({"reportFile": str(args.report_file), "counts": report["counts"], "pending": report["pending"], "conflicts": len(report["plannedConflicts"]) + len(report["executionConflicts"])}, indent=2))
    else:
        print(f"BULK REPORT: {args.report_file}\n  outcomes: {dict(counts)}  pending: {report['pending']}")
        print(f"  conflicts: {len(report['plannedConflicts'])} planned, {len(report['executionConflicts'])} new. Resolve manually outside this script.")
    return 1 if report["pending"] else 0


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    base = base_url(args.url, args.allow_http)
    key = load_key(args.env_file)
    if args.command == "plan": return do_plan(args, base, key)
    return do_apply(args, base, key)


if __name__ == "__main__":
    try: sys.exit(main())
    except CliError as exc:
        print("hubspot-sync: " + str(exc), file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("\nInterrupted. Resume with hubspot-sync resume.", file=sys.stderr)
        sys.exit(130)
