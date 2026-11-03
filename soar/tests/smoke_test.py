"""Smoke test of a SOAR release on the "test" aliases. Used by the soar-release pipeline.

It invokes each function through its test alias and checks the result:
  1. ingest rejects a request without the token (401)
  2. ingest accepts a valid, empty webhook message (202, nothing queued)
  3. processor handles a high-level event: recorded, blocked for the test block time, no failures
  4. cleanup runs without errors
It also checks that the test alias runs the version that was just published.

Needs the AWS CLI with credentials, and the environment variables SOAR_WEBHOOK_TOKEN and
RUN_ID. Usage: python3 soar/tests/smoke_test.py '{"ingest": "5", "processor": "7", "cleanup": "5"}'
"""
import json
import os
import subprocess
import sys
import tempfile
import time

PREFIX = "innovatech-soar"
EVENTS_TABLE = f"{PREFIX}-events"
TEST_SOURCE = "203.0.113.99"  # documentation range (RFC 5737), never a real client


def aws(*args):
    result = subprocess.run(["aws", *args, "--output", "json"], capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"aws {' '.join(args[:2])} failed: {result.stderr.strip()}")
    return json.loads(result.stdout) if result.stdout.strip() else {}


def invoke(function, payload, expected_version):
    with tempfile.TemporaryDirectory() as tmp:
        request, response = os.path.join(tmp, "in.json"), os.path.join(tmp, "out.json")
        with open(request, "w") as f:
            json.dump(payload, f)
        meta = aws("lambda", "invoke", "--function-name", f"{PREFIX}-{function}", "--qualifier", "test",
                   "--cli-binary-format", "raw-in-base64-out", "--payload", f"file://{request}", response)
        with open(response) as f:
            body = json.load(f)
    check(f"{function}: test alias runs version {expected_version}",
          meta.get("ExecutedVersion") == expected_version, meta.get("ExecutedVersion"))
    check(f"{function}: no function error", "FunctionError" not in meta, body)
    return body


FAILURES = []


def check(name, ok, detail=""):
    print(f"[{'PASS' if ok else 'FAIL'}] {name}" + ("" if ok else f"  ->  {detail}"))
    if not ok:
        FAILURES.append(name)


def main(versions):
    run_id = os.environ.get("RUN_ID", str(int(time.time())))
    token = os.environ["SOAR_WEBHOOK_TOKEN"]

    # 1 and 2: ingest
    body = invoke("ingest", {"headers": {}, "body": "{}"}, versions["ingest"])
    check("ingest: request without token is rejected (401)", body.get("statusCode") == 401, body)
    body = invoke("ingest", {"headers": {"authorization": f"Bearer {token}"}, "body": json.dumps({"alerts": []})},
                  versions["ingest"])
    check("ingest: valid empty message is accepted (202)", body.get("statusCode") == 202, body)

    # 3: processor, one high-level event as SQS would deliver it
    event_id = f"release-smoke-{run_id}"
    event = {
        "event_id": event_id, "received_at": int(time.time()), "starts_at": time.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "rule": "Release smoke test", "type": "ssh_bruteforce", "severity": "high",
        "source_ip": TEST_SOURCE, "target": "onprem-gw", "count": 10,
        "summary": "Synthetic event sent by the soar-release pipeline",
    }
    body = invoke("processor", {"Records": [{"messageId": event_id, "body": json.dumps(event)}]},
                  versions["processor"])
    check("processor: no failed events", body.get("batchItemFailures") == [], body)

    item = aws("dynamodb", "get-item", "--table-name", EVENTS_TABLE, "--consistent-read",
               "--key", json.dumps({"event_id": {"S": event_id}})).get("Item", {})
    status = item.get("status", {}).get("S")
    environment = item.get("environment", {}).get("S")
    block = item.get("results", {}).get("M", {}).get("block", {}).get("S", "")
    check("processor: event recorded with status done", status == "done", status)
    check("processor: handled as the test environment", environment == "test", environment)
    check("processor: source blocked with the test block time",
          block.startswith("blocked for 5 minutes") or block == "already blocked", block)

    # 4: cleanup
    body = invoke("cleanup", {}, versions["cleanup"])
    check("cleanup: ran and reported its result", "removed" in body, body)

    print(f"\n{len(FAILURES)} check(s) failed" if FAILURES else "\nAll smoke tests passed")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main(json.loads(sys.argv[1])))
