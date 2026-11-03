"""Cleanup function: started by EventBridge every minute.

Removes network ACL deny rules whose block time has passed, and reports the number
of active blocks to CloudWatch for the dashboard.
"""
import json
import os
import time

import boto3
from botocore.exceptions import ClientError

from soar_common import emit_metrics

ec2 = boto3.client("ec2")
blocks_table = boto3.resource("dynamodb").Table(os.environ["BLOCKS_TABLE"])
NACL_ID = os.environ["NACL_ID"]


def handler(event, context):
    now = int(time.time())
    items = blocks_table.scan().get("Items", [])
    removed = 0
    for item in items:
        if int(item["expires_at"]) > now:
            continue
        try:
            ec2.delete_network_acl_entry(NetworkAclId=NACL_ID, RuleNumber=int(item["rule_number"]), Egress=False)
        except ClientError as exc:
            if exc.response["Error"]["Code"] != "InvalidNetworkAclEntry.NotFound":
                raise
        blocks_table.delete_item(Key={"ip": item["ip"]})
        removed += 1
        print(json.dumps({"unblocked": item["ip"], "rule_number": int(item["rule_number"])}))
    emit_metrics({"ActiveBlocks": len(items) - removed, "BlocksRemoved": removed})
    return {"removed": removed}
