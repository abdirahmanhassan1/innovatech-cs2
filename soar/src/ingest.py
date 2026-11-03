"""Ingest function: receives the Grafana webhook through API Gateway.

It checks the token, converts every firing alert to the SOAR event format and puts
the events in the SQS queue. The processing happens in the processor function.
"""
import base64
import hmac
import json
import os

import boto3

from soar_common import emit_metrics, parse_webhook

sqs = boto3.client("sqs")
QUEUE_URL = os.environ["QUEUE_URL"]
TOKEN = os.environ["WEBHOOK_TOKEN"]


def response(status, body):
    return {"statusCode": status, "headers": {"Content-Type": "application/json"}, "body": json.dumps(body)}


def handler(event, context):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    supplied = headers.get("authorization", "")
    if not hmac.compare_digest(supplied, f"Bearer {TOKEN}"):
        emit_metrics({"RejectedRequests": 1})
        return response(401, {"error": "unauthorized"})

    body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        body = base64.b64decode(body).decode()
    try:
        events = parse_webhook(body)
    except (ValueError, json.JSONDecodeError) as exc:
        emit_metrics({"RejectedRequests": 1})
        return response(400, {"error": str(exc)})

    for soar_event in events:
        sqs.send_message(QueueUrl=QUEUE_URL, MessageBody=json.dumps(soar_event))
    emit_metrics({"EventsQueued": len(events)})
    return response(202, {"queued": len(events)})
