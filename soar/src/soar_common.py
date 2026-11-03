"""Shared logic of the SOAR: event format, rule engine, allow list and metrics.

The functions in this file have no AWS dependencies, so the rule engine can be
tested without an AWS account (see soar/tests).
"""
import hashlib
import ipaddress
import json
import os
import time

LEVEL_ORDER = ["low", "medium", "high"]


def load_rules(path=None):
    path = path or os.path.join(os.path.dirname(__file__), "rules.json")
    with open(path) as f:
        return json.load(f)


def environment_from_arn(function_arn):
    """The alias in the invoked ARN decides the environment: ...:function:name:prod.

    Anything else (no alias, $LATEST, a version number) is treated as test, the safe default.
    """
    qualifier = (function_arn or "").split(":")[-1]
    return "prod" if qualifier == "prod" else "test"


def normalize_alert(alert, received_at=None):
    """Turn one alert from the Grafana webhook message into the SOAR event format."""
    labels = alert.get("labels") or {}
    values = alert.get("values") or {}
    starts_at = alert.get("startsAt", "")
    fingerprint = alert.get("fingerprint", "")
    event_id = hashlib.sha256(f"{fingerprint}|{starts_at}".encode()).hexdigest()[:32]
    count = values.get("A")
    return {
        "event_id": event_id,
        "received_at": received_at or int(time.time()),
        "starts_at": starts_at,
        "rule": labels.get("alertname", "unknown"),
        "type": labels.get("alert_type", "unknown"),
        "severity": labels.get("severity", "unknown"),
        "source_ip": labels.get("src_ip", ""),
        "target": labels.get("host", ""),
        "count": int(count) if isinstance(count, (int, float)) else None,
        "summary": (alert.get("annotations") or {}).get("summary", ""),
    }


def parse_webhook(body):
    """Return the firing alerts of a Grafana webhook message as SOAR events."""
    message = json.loads(body) if isinstance(body, str) else body
    alerts = message.get("alerts")
    if not isinstance(alerts, list):
        raise ValueError("message has no alerts list")
    now = int(time.time())
    return [normalize_alert(a, now) for a in alerts if a.get("status") == "firing"]


def decide_level(event, rules):
    """Level from the alert type. Unknown types fall back to the severity label, then to the default."""
    level = rules["types"].get(event.get("type"))
    if level is None and event.get("severity") in LEVEL_ORDER:
        level = event["severity"]
    return level or rules["default_level"]


def is_allowed(ip, allow_list):
    try:
        address = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return any(address in ipaddress.ip_network(net, strict=False) for net in allow_list)


def decide(event, rules, environment, extra_allow=(), admin_cidr=""):
    """Rule engine: which actions to take for one event.

    Returns the level, the planned actions and, when a block is skipped, the reason.
    """
    level = decide_level(event, rules)
    actions = list(rules["levels"][level])
    env = rules["environments"][environment]
    allow_list = list(rules["allow_list"]) + [a for a in extra_allow if a]
    if env["allow_admin_ip"] and admin_cidr:
        allow_list.append(admin_cidr)

    skipped = None
    if "block" in actions:
        ip = event.get("source_ip", "")
        if not ip:
            skipped = "no source address"
        elif is_allowed(ip, allow_list):
            skipped = "source address is on the allow list"
        if skipped:
            actions.remove("block")
    return {
        "level": level,
        "actions": actions,
        "block_skipped": skipped,
        "block_minutes": env["block_minutes"],
        "environment": environment,
    }


def free_rule_number(used, max_blocks):
    """Lowest network ACL rule number between 1 and max_blocks that is not in use."""
    for number in range(1, max_blocks + 1):
        if number not in used:
            return number
    return None


def emit_metrics(metrics, dimensions=None):
    """Write CloudWatch metrics in the embedded metric format (one log line, no API call)."""
    dimensions = dimensions or {}
    record = {
        "_aws": {
            "Timestamp": int(time.time() * 1000),
            "CloudWatchMetrics": [{
                "Namespace": "Innovatech/SOAR",
                "Dimensions": [list(dimensions.keys())],
                "Metrics": [{"Name": name, "Unit": "Count"} for name in metrics],
            }],
        },
        **dimensions,
        **metrics,
    }
    print(json.dumps(record))
