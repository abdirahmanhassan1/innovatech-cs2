"""Unit tests for the SOAR rule engine. Run from the repository root:

    python3 -m unittest discover -s soar/tests -v
"""
import json
import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "src"))

from soar_common import (decide, environment_from_arn, free_rule_number,  # noqa: E402
                         is_allowed, load_rules, parse_webhook)

RULES = load_rules(os.path.join(ROOT, "rules", "rules.json"))
GATEWAYS = ["3.65.238.247/32", "35.157.144.233/32"]


def event(alert_type, ip="203.0.113.50", severity="high"):
    return {"event_id": "x", "type": alert_type, "severity": severity, "source_ip": ip, "target": "onprem-gw"}


class RuleEngineTest(unittest.TestCase):
    def test_bruteforce_is_high_and_blocks(self):
        d = decide(event("ssh_bruteforce"), RULES, "prod", GATEWAYS)
        self.assertEqual(d["level"], "high")
        self.assertEqual(d["actions"], ["record", "notify", "block"])

    def test_login_failures_are_medium_without_block(self):
        d = decide(event("ssh_login_failures", severity="medium"), RULES, "prod")
        self.assertEqual(d["level"], "medium")
        self.assertEqual(d["actions"], ["record", "notify"])

    def test_unknown_type_uses_severity_label(self):
        self.assertEqual(decide(event("something_new", severity="medium"), RULES, "prod")["level"], "medium")

    def test_unknown_type_and_severity_is_low(self):
        d = decide(event("something_new", severity="unknown"), RULES, "prod")
        self.assertEqual((d["level"], d["actions"]), ("low", ["record"]))

    def test_internal_addresses_are_never_blocked(self):
        d = decide(event("port_scan", ip="10.10.1.10"), RULES, "prod")
        self.assertNotIn("block", d["actions"])
        self.assertEqual(d["block_skipped"], "source address is on the allow list")

    def test_gateways_are_never_blocked(self):
        d = decide(event("port_scan", ip="35.157.144.233"), RULES, "prod", GATEWAYS)
        self.assertNotIn("block", d["actions"])

    def test_admin_ip_allowed_in_prod_only(self):
        prod = decide(event("ssh_bruteforce", ip="145.93.44.22"), RULES, "prod", GATEWAYS, "145.93.44.22/32")
        test = decide(event("ssh_bruteforce", ip="145.93.44.22"), RULES, "test", GATEWAYS, "145.93.44.22/32")
        self.assertNotIn("block", prod["actions"])
        self.assertIn("block", test["actions"])

    def test_block_time_per_environment(self):
        self.assertEqual(decide(event("ssh_bruteforce"), RULES, "test")["block_minutes"], 5)
        self.assertEqual(decide(event("ssh_bruteforce"), RULES, "prod")["block_minutes"], 30)

    def test_missing_source_is_not_blocked(self):
        d = decide(event("ssh_bruteforce", ip=""), RULES, "prod")
        self.assertNotIn("block", d["actions"])


class HelperTest(unittest.TestCase):
    def test_environment_from_alias(self):
        base = "arn:aws:lambda:eu-central-1:123456789012:function:innovatech-soar-processor"
        self.assertEqual(environment_from_arn(base + ":prod"), "prod")
        self.assertEqual(environment_from_arn(base + ":test"), "test")
        self.assertEqual(environment_from_arn(base), "test")
        self.assertEqual(environment_from_arn(base + ":7"), "test")

    def test_free_rule_number(self):
        self.assertEqual(free_rule_number(set(), 15), 1)
        self.assertEqual(free_rule_number({1, 2, 4}, 15), 3)
        self.assertIsNone(free_rule_number(set(range(1, 16)), 15))

    def test_is_allowed(self):
        self.assertTrue(is_allowed("172.16.99.2", ["172.16.0.0/12"]))
        self.assertFalse(is_allowed("203.0.113.5", ["10.0.0.0/8"]))
        self.assertFalse(is_allowed("not-an-ip", ["10.0.0.0/8"]))


class WebhookTest(unittest.TestCase):
    def test_only_firing_alerts_become_events(self):
        message = {"alerts": [
            {"status": "firing", "fingerprint": "abc", "startsAt": "2026-11-03T10:00:00Z",
             "labels": {"alertname": "SSH brute force", "alert_type": "ssh_bruteforce",
                        "severity": "high", "src_ip": "203.0.113.50", "host": "onprem-gw"},
             "values": {"A": 12, "C": 1}},
            {"status": "resolved", "fingerprint": "def", "labels": {}},
        ]}
        events = parse_webhook(json.dumps(message))
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["source_ip"], "203.0.113.50")
        self.assertEqual(events[0]["count"], 12)
        self.assertEqual(len(events[0]["event_id"]), 32)

    def test_same_alert_gives_same_event_id(self):
        alert = {"status": "firing", "fingerprint": "abc", "startsAt": "t", "labels": {}}
        a = parse_webhook({"alerts": [alert]})[0]["event_id"]
        b = parse_webhook({"alerts": [alert]})[0]["event_id"]
        self.assertEqual(a, b)

    def test_message_without_alerts_is_rejected(self):
        with self.assertRaises(ValueError):
            parse_webhook("{}")


if __name__ == "__main__":
    unittest.main()
