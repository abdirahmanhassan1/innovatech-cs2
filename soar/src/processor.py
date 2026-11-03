"""Processor function: the rule engine and the response actions.

Reads events from SQS, decides the response level and carries out the actions:
A1 record (DynamoDB), A3 block (network ACL deny rule) and A2 notify (SNS).
A failed event is retried by SQS and moves to the dead-letter queue after three attempts.
"""
import json
import os
import time

import boto3
from botocore.exceptions import ClientError

from soar_common import decide, emit_metrics, environment_from_arn, free_rule_number, load_rules

RULES = load_rules()
ec2 = boto3.client("ec2")
sns = boto3.client("sns")
dynamodb = boto3.resource("dynamodb")
events_table = dynamodb.Table(os.environ["EVENTS_TABLE"])
blocks_table = dynamodb.Table(os.environ["BLOCKS_TABLE"])
NACL_ID = os.environ["NACL_ID"]
TOPIC_ARN = os.environ["TOPIC_ARN"]
ADMIN_CIDR = os.environ.get("ADMIN_CIDR", "")
GATEWAY_CIDRS = [c for c in os.environ.get("GATEWAY_CIDRS", "").split(",") if c]


def record(event, decision, results, status):
    """A1: save the event and the decision. Kept for the retention period, then deleted by DynamoDB TTL."""
    expire_at = int(time.time()) + RULES["event_retention_days"] * 86400
    events_table.put_item(Item={
        **{k: v for k, v in event.items() if v is not None and v != ""},
        "level": decision["level"],
        "environment": decision["environment"],
        "planned_actions": decision["actions"],
        "results": results,
        "status": status,
        "expire_at": expire_at,
    })


def block(event, decision):
    """A3: add a deny rule for the source address to the office network ACL."""
    ip = event["source_ip"]
    now = int(time.time())
    expires_at = now + decision["block_minutes"] * 60

    active = blocks_table.scan(ProjectionExpression="ip, rule_number").get("Items", [])
    if any(item["ip"] == ip for item in active):
        return "already blocked"
    if len(active) >= RULES["max_blocks"]:
        return "not blocked: maximum number of blocks reached"

    used = {int(item["rule_number"]) for item in active}
    for _ in range(RULES["max_blocks"]):
        number = free_rule_number(used, RULES["max_blocks"])
        if number is None:
            return "not blocked: no free rule number"
        try:
            blocks_table.put_item(
                Item={"ip": ip, "rule_number": number, "expires_at": expires_at,
                      "created_at": now, "event_id": event["event_id"]},
                ConditionExpression="attribute_not_exists(ip)",
            )
        except ClientError as exc:
            if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
                return "already blocked"
            raise
        try:
            ec2.create_network_acl_entry(
                NetworkAclId=NACL_ID, RuleNumber=number, Egress=False, Protocol="-1",
                RuleAction="deny", CidrBlock=f"{ip}/32",
            )
            return f"blocked for {decision['block_minutes']} minutes (network ACL rule {number})"
        except ClientError as exc:
            blocks_table.delete_item(Key={"ip": ip})
            if exc.response["Error"]["Code"] == "NetworkAclEntryAlreadyExists":
                used.add(number)
                continue
            raise
    return "not blocked: no free rule number"


def notify(event, decision, results):
    """A2: email to the administrator through SNS."""
    subject = f"[SOAR] {decision['level'].upper()} {event['type']} from {event['source_ip'] or 'unknown'} on {event['target']}"
    lines = [
        f"Alert:        {event['rule']}",
        f"Type:         {event['type']}",
        f"Level:        {decision['level']} ({decision['environment']})",
        f"Source:       {event['source_ip']}",
        f"Target:       {event['target']}",
        f"Count:        {event.get('count')}",
        f"Started at:   {event['starts_at']}",
        f"Event ID:     {event['event_id']}",
        "",
        "Actions:",
    ] + [f"  {name}: {result}" for name, result in results.items()]
    sns.publish(TopicArn=TOPIC_ARN, Subject=subject[:99], Message="\n".join(lines))


def process(event, environment):
    decision = decide(event, RULES, environment, GATEWAY_CIDRS, ADMIN_CIDR)
    results = {}
    if decision["block_skipped"]:
        results["block"] = f"skipped: {decision['block_skipped']}"

    record(event, decision, results, "processing")
    results["record"] = "saved"

    if "block" in decision["actions"]:
        results["block"] = block(event, decision)
    if "notify" in decision["actions"]:
        notify(event, decision, results)
        results["notify"] = "email sent"

    record(event, decision, results, "done")
    emit_metrics({"EventsProcessed": 1}, {"Level": decision["level"]})
    for action in results:
        emit_metrics({"ActionsSucceeded": 1}, {"Action": action})
    print(json.dumps({"event_id": event["event_id"], "decision": decision, "results": results}))


def handler(event, context):
    environment = environment_from_arn(context.invoked_function_arn)
    failures = []
    for message in event.get("Records", []):
        try:
            process(json.loads(message["body"]), environment)
        except Exception as exc:  # the message goes back to the queue and is retried
            print(json.dumps({"error": str(exc), "message_id": message["messageId"]}))
            emit_metrics({"ActionsFailed": 1}, {"Action": "process"})
            failures.append({"itemIdentifier": message["messageId"]})
    return {"batchItemFailures": failures}
