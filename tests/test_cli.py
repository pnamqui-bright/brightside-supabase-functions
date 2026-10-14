"""Bulk-only CLI integration tests against a localhost fake, not HubSpot or Supabase."""
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
KEY = "sb_secret_local_mock_0123456789abcdef"

class FakeApi:
    def __init__(self):
        self.calls=[]
        self.fail_once=False
        outer=self
        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body=json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                outer.calls.append((self.path,body,self.headers.get("apikey")))
                if self.headers.get("apikey") != KEY:
                    return self.respond(401,{"error":"unauthorized"})
                if self.path.endswith("hubspot-bulk-plan"):
                    entity=body["objectType"]
                    if body["source"]=="supabase":
                        ids=["c1","c2","c3"] if entity=="companies" else ["p1"]
                        return self.respond(200,{"source":"supabase","objectType":entity,"ids":ids,"nextCursor":None})
                    records=([
                        {"entity":"companies","hubspotId":"123","supabaseId":"c1","status":"work","operations":[{"entity":"companies","id":"123","direction":"pull"}]},
                        {"entity":"companies","hubspotId":"124","supabaseId":"c2","status":"conflict","reason":"both_sides_changed_since_last_sync","operations":[]},
                    ] if entity=="companies" else [
                        {"entity":"contacts","hubspotId":"345","supabaseId":"p1","status":"work","operations":[{"entity":"contacts","id":"p1","direction":"push"}]}
                    ])
                    return self.respond(200,{"source":"hubspot","objectType":entity,"records":records,"nextCursor":None})
                if self.path.endswith("hubspot-bulk-execute"):
                    status="failed" if outer.fail_once else "applied"
                    outer.fail_once=False
                    return self.respond(200,{"objectType":body["objectType"],"direction":body["direction"],"results":[{"id":x,"status":status,"fieldsUpdated":0 if status=="failed" else 1} for x in body["ids"]]})
                return self.respond(404,{"error":"no such endpoint"})
            def respond(self,code,payload):
                data=json.dumps(payload).encode()
                self.send_response(code)
                self.send_header("Content-Type","application/json")
                self.send_header("Content-Length",str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            def log_message(self,*args):pass
        self.http=ThreadingHTTPServer(("127.0.0.1",0),Handler)
        self.thread=threading.Thread(target=self.http.serve_forever,daemon=True)
        self.url=f"http://127.0.0.1:{self.http.server_port}"
    def __enter__(self):self.thread.start();return self
    def __exit__(self,*_):self.http.shutdown();self.http.server_close();self.thread.join(timeout=3)

def run(*args, key=KEY):
    env=dict(os.environ)
    env.pop("SUPABASE_SECRET_KEY",None)
    if key is not None:env["SUPABASE_SECRET_KEY"]=key
    return subprocess.run([sys.executable,str(SCRIPT),*map(str,args)],capture_output=True,text=True,input="",env=env,timeout=10)

class TestBulkCli(unittest.TestCase):
    def test_bulk_only_no_id_interface(self):
        h=run("--help",key=None)
        self.assertEqual(h.returncode,0)
        self.assertIn("BULK-ONLY",h.stdout)
        self.assertNotIn("--id",h.stdout)
        self.assertEqual(run("pull","companies").returncode,2)

    def test_plan_reads_both_inventories_no_writes(self):
        with FakeApi() as fake,tempfile.TemporaryDirectory() as tmp:
            f=Path(tmp)/"plan.json"
            result=run("plan","--plan-file",f,"--url",fake.url,"--allow-http")
            self.assertEqual(result.returncode,0,result.stderr)
            plan=json.loads(f.read_text())
            self.assertTrue(plan["complete"])
            self.assertEqual(len(plan["operations"]),2)
            self.assertEqual(len(plan["conflicts"]),1)
            self.assertEqual(len(fake.calls),4)
            self.assertTrue(all("bulk-plan" in x[0] and x[2]==KEY for x in fake.calls))
            self.assertIn("unmatched_outbound_no_creation",[x["reason"] for x in plan["skipped"]])

    def test_checkpoint_resume_retries_only_failed(self):
        with FakeApi() as fake,tempfile.TemporaryDirectory() as tmp:
            args=["--plan-file",Path(tmp)/"plan.json","--checkpoint-file",Path(tmp)/"cp.json","--report-file",Path(tmp)/"report.json","--url",fake.url,"--allow-http"]
            self.assertEqual(run("plan",*args).returncode,0)
            fake.fail_once=True
            self.assertEqual(run("apply","--yes",*args).returncode,1)
            self.assertEqual(len(json.loads(Path(tmp,"cp.json").read_text())["completed"]),1)
            self.assertEqual(run("resume","--yes",*args).returncode,0)
            self.assertEqual(len(json.loads(Path(tmp,"cp.json").read_text())["completed"]),2)
            self.assertEqual(json.loads(Path(tmp,"report.json").read_text())["pending"],0)

    def test_force_is_only_selected_direction(self):
        with FakeApi() as fake,tempfile.TemporaryDirectory() as tmp:
            args=["--plan-file",Path(tmp)/"plan.json","--checkpoint-file",Path(tmp)/"cp.json","--report-file",Path(tmp)/"r.json","--url",fake.url,"--allow-http"]
            self.assertEqual(run("plan",*args).returncode,0)
            self.assertEqual(run("apply","--yes","--force=push",*args).returncode,0)
            forced=[x[1] for x in fake.calls if x[1].get("force")]
            self.assertEqual(len(forced),1)
            self.assertEqual(forced[0]["ids"],["c2"])
            self.assertEqual(forced[0]["direction"],"push")
            self.assertEqual(forced[0]["confirm"],"FORCE_PUSH")

    def test_tampered_plan_and_missing_key_fail_closed(self):
        self.assertEqual(run("plan",key=None).returncode,1)
        with FakeApi() as fake,tempfile.TemporaryDirectory() as tmp:
            f=Path(tmp)/"plan.json"
            args=["--plan-file",f,"--checkpoint-file",Path(tmp)/"cp.json","--url",fake.url,"--allow-http"]
            self.assertEqual(run("plan",*args).returncode,0)
            p=json.loads(f.read_text());p["operations"][0]["id"]="999";f.write_text(json.dumps(p))
            self.assertEqual(run("apply","--yes",*args).returncode,1)
            self.assertFalse(any("bulk-execute" in x[0] for x in fake.calls))

if __name__=="__main__":unittest.main()
