"""No network, AWS mutations or Slack delivery: SDK stubs and unit mocks only."""
import json
import os
import unittest
from unittest.mock import Mock, patch

import boto3
from botocore.exceptions import ClientError
from botocore.stub import Stubber

import lambda_function as remediation

GROUP_ID = "sg-0123456789abcdef0"
RULE_ID = "sgr-0123456789abcdef0"
OTHER_RULE_ID = "sgr-1123456789abcdef0"
CONFIG = {"ACCOUNT_ID": "123456789012", "TARGET_REGION": "ap-northeast-2",
          "PROJECT_TAG": "food-delivery", "ENV_TAG": "dev", "MANAGED_BY_TAG": "terraform",
          "VPC_ID": "vpc-0123456789abcdef0", "SLACK_WEBHOOK_URL": "https://hooks.slack.com/services/TEST/ONLY/SECRET"}


def event(name="AuthorizeSecurityGroupIngress"):
    return {"source": "aws.ec2", "detail-type": "AWS API Call via CloudTrail",
            "account": CONFIG["ACCOUNT_ID"], "region": CONFIG["TARGET_REGION"],
            "detail": {"eventSource": "ec2.amazonaws.com", "eventName": name,
                       "requestParameters": {"groupId": GROUP_ID}, "eventTime": "2026-10-14T00:00:00Z",
                       "userIdentity": {"type": "AssumedRole", "sessionContext": {"sessionIssuer": {
                           "arn": "arn:aws:iam::123456789012:role/operator"}}}}}


def group():
    return {"GroupId": GROUP_ID, "GroupName": "project-node", "OwnerId": CONFIG["ACCOUNT_ID"],
            "VpcId": CONFIG["VPC_ID"], "Tags": [
                {"Key": key, "Value": value} for key, value in
                (("Project", "food-delivery"), ("Environment", "dev"), ("ManagedBy", "terraform"))]}


def rule(**updates):
    result = {"SecurityGroupRuleId": RULE_ID, "GroupId": GROUP_ID, "IsEgress": False,
              "IpProtocol": "tcp", "FromPort": 22, "ToPort": 22, "CidrIpv4": "0.0.0.0/0"}
    result.update(updates)
    return result


def error(code):
    return ClientError({"Error": {"Code": code, "Message": "SECRET_PASSWORD webhook SECRET_TOKEN"}}, "EC2")


class RemediationTest(unittest.TestCase):
    def setUp(self):
        self.environment = patch.dict(os.environ, CONFIG)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.ec2 = Mock()
        self.ec2.describe_security_groups.return_value = {"SecurityGroups": [group()]}
        self.ec2.get_paginator.return_value.paginate.return_value = [{"SecurityGroupRules": [rule()]}]
        self.ec2.describe_security_group_rules.return_value = {"SecurityGroupRules": [rule()]}
        self.ec2.revoke_security_group_ingress.return_value = {"Return": True}
        self.notify = Mock()

    def run_event(self, incoming=None, rules=None):
        if rules is not None:
            self.ec2.get_paginator.return_value.paginate.return_value = [{"SecurityGroupRules": rules}]
        return remediation.remediate(incoming or event(), self.ec2, self.notify)

    def test_ipv4_exact_rule_only(self):
        result = self.run_event(rules=[rule(), rule(SecurityGroupRuleId=OTHER_RULE_ID, FromPort=443, ToPort=443)])
        self.assertEqual(result["revoked"], 1)
        self.ec2.revoke_security_group_ingress.assert_called_once_with(GroupId=GROUP_ID, SecurityGroupRuleIds=[RULE_ID])
        self.notify.assert_called_once()
        self.assertEqual(self.notify.call_args.args[0]["actor"], "arn:aws:iam::123456789012:role/operator")

    def test_ipv6(self):
        current = rule(CidrIpv4=None, CidrIpv6="::/0")
        self.ec2.describe_security_group_rules.return_value = {"SecurityGroupRules": [current]}
        self.assertEqual(self.run_event(rules=[current])["revoked"], 1)
        self.assertEqual(self.notify.call_args.args[0]["cidr"], "::/0")

    def test_port_ranges_and_all_protocol(self):
        for updates in ({"FromPort": 20, "ToPort": 30}, {"FromPort": 0, "ToPort": 65535},
                        {"IpProtocol": "-1", "FromPort": None, "ToPort": None}, {"IpProtocol": "6"}):
            with self.subTest(updates=updates):
                current = rule(**updates)
                self.ec2.describe_security_group_rules.return_value = {"SecurityGroupRules": [current]}
                self.assertEqual(self.run_event(rules=[current])["revoked"], 1)

    def test_safe_rules_preserved(self):
        for updates in ({"CidrIpv4": "203.0.113.5/32"}, {"FromPort": 80, "ToPort": 80},
                        {"FromPort": 443, "ToPort": 443}, {"FromPort": 3306, "ToPort": 3306},
                        {"FromPort": 6379, "ToPort": 6379}, {"IpProtocol": "icmp"}, {"IpProtocol": "udp"},
                        {"IsEgress": True}, {"CidrIpv4": None, "ReferencedGroupInfo": {"GroupId": GROUP_ID}},
                        {"CidrIpv4": None, "PrefixListId": "pl-test"}, {"FromPort": None},
                        {"CidrIpv4": "0.0.0.0/1"}, {"CidrIpv4": None, "CidrIpv6": "2001:db8::/32"}):
            with self.subTest(updates=updates):
                self.assertEqual(self.run_event(rules=[rule(**updates)])["revoked"], 0)
        self.ec2.revoke_security_group_ingress.assert_not_called()
        self.notify.assert_not_called()

    def test_other_project_environment_or_management_tag(self):
        for key in ("Project", "Environment", "ManagedBy"):
            with self.subTest(key=key):
                current = group()
                next(tag for tag in current["Tags"] if tag["Key"] == key)["Value"] = "other"
                self.ec2.describe_security_groups.return_value = {"SecurityGroups": [current]}
                self.assertEqual(self.run_event()["status"], "outside_project")
        self.ec2.revoke_security_group_ingress.assert_not_called()

    def test_default_wrong_vpc_owner_and_missing_tags(self):
        for updates in ({"GroupName": "default"}, {"VpcId": "vpc-foreign"},
                        {"OwnerId": "999999999999"}, {"Tags": []}):
            with self.subTest(updates=updates):
                self.ec2.describe_security_groups.return_value = {"SecurityGroups": [{**group(), **updates}]}
                self.assertEqual(self.run_event()["status"], "outside_project")
        self.ec2.revoke_security_group_ingress.assert_not_called()

    def test_already_deleted_and_duplicate_delivery(self):
        self.assertEqual(self.run_event()["revoked"], 1)
        self.assertEqual(self.run_event(rules=[])["status"], "already_safe")
        self.ec2.revoke_security_group_ingress.assert_called_once()
        self.notify.assert_called_once()

    def test_missing_rule_during_recheck(self):
        self.ec2.describe_security_group_rules.side_effect = error("InvalidSecurityGroupRuleId.NotFound")
        self.assertEqual(self.run_event()["status"], "already_safe")
        self.ec2.revoke_security_group_ingress.assert_not_called()

    def test_deleted_during_revoke(self):
        self.ec2.revoke_security_group_ingress.side_effect = error("InvalidPermission.NotFound")
        self.assertEqual(self.run_event()["revoked"], 0)
        self.notify.assert_not_called()

    def test_changed_to_safe_before_execution(self):
        self.ec2.describe_security_group_rules.return_value = {"SecurityGroupRules": [rule(CidrIpv4="203.0.113.5/32")]}
        self.assertEqual(self.run_event()["revoked"], 0)
        self.ec2.revoke_security_group_ingress.assert_not_called()

    def test_boundary_changed_before_revoke(self):
        foreign = group()
        foreign["Tags"] = []
        self.ec2.describe_security_groups.side_effect = [{"SecurityGroups": [group()]}, {"SecurityGroups": [foreign]}]
        self.assertEqual(self.run_event()["revoked"], 0)
        self.ec2.revoke_security_group_ingress.assert_not_called()

    def test_modify_private_to_public_checks_current_state(self):
        incoming = event("ModifySecurityGroupRules")
        incoming["detail"]["requestParameters"]["securityGroupRuleSet"] = {"items": [{
            "securityGroupRuleId": RULE_ID, "securityGroupRule": {"cidrIpv4": "0.0.0.0/0"}}]}
        self.assertEqual(self.run_event(incoming)["revoked"], 1)

    def test_failed_api_and_wrong_event_scope(self):
        for update in ({"account": "999999999999"}, {"region": "us-east-1"}, {"source": "aws.s3"}):
            self.assertEqual(self.run_event({**event(), **update})["status"], "ignored")
        for update in ({"errorCode": "UnauthorizedOperation"}, {"eventName": "RevokeSecurityGroupIngress"}):
            incoming = event()
            incoming["detail"].update(update)
            self.assertEqual(self.run_event(incoming)["status"], "ignored")
        self.ec2.describe_security_groups.assert_not_called()

    def test_malformed_events_create_no_sdk_client(self):
        malformed_name = event()
        malformed_name["detail"]["eventName"] = []
        for incoming in (None, [], {}, {"detail": []}, malformed_name,
                         {**event(), "detail": {"requestParameters": None}}):
            with patch.object(remediation.boto3, "client") as client:
                self.assertEqual(remediation.handler(incoming, None)["status"], "ignored")
                client.assert_not_called()

    def test_slack_failure_does_not_undo_revoke_or_leak_secret(self):
        self.notify.side_effect = RuntimeError(CONFIG["SLACK_WEBHOOK_URL"] + " PASSWORD_SECRET")
        with self.assertLogs(remediation.LOGGER, "INFO") as logs:
            self.assertEqual(self.run_event()["revoked"], 1)
        self.ec2.revoke_security_group_ingress.assert_called_once()
        self.assertIn("Slack notification failed", " ".join(logs.output))
        self.assertNotIn("PASSWORD_SECRET", " ".join(logs.output))
        self.assertNotIn(CONFIG["SLACK_WEBHOOK_URL"], " ".join(logs.output))

    def test_revoke_failures_raise_safe_error_for_async_retry(self):
        self.ec2.revoke_security_group_ingress.side_effect = error("UnauthorizedOperation")
        with self.assertLogs(remediation.LOGGER, "ERROR") as logs:
            with self.assertRaisesRegex(RuntimeError, "^Security group remediation failed$"):
                self.run_event()
        self.notify.assert_not_called()
        self.assertNotIn("SECRET", " ".join(logs.output))

    def test_multiple_pages_only_offending_ids(self):
        second = rule(SecurityGroupRuleId=OTHER_RULE_ID)
        self.ec2.get_paginator.return_value.paginate.return_value = [
            {"SecurityGroupRules": [rule(FromPort=443, ToPort=443)]}, {"SecurityGroupRules": [second]}]
        self.ec2.describe_security_group_rules.return_value = {"SecurityGroupRules": [second]}
        self.assertEqual(self.run_event()["revoked"], 1)
        self.ec2.revoke_security_group_ingress.assert_called_once_with(GroupId=GROUP_ID, SecurityGroupRuleIds=[OTHER_RULE_ID])

    def test_unknown_actor_safe_and_event_not_logged(self):
        incoming = event()
        incoming["detail"]["userIdentity"] = {"arn": "TOKEN_SECRET", "accessKeyId": "KEY_SECRET"}
        incoming["detail"]["requestParameters"]["unexpectedSecret"] = "PASSWORD_SECRET"
        with self.assertLogs(remediation.LOGGER, "INFO") as logs:
            self.run_event(incoming)
        self.assertEqual(self.notify.call_args.args[0]["actor"], "unknown")
        self.assertNotIn("SECRET", " ".join(logs.output))

    def test_actor_shapes(self):
        self.assertEqual(remediation._actor({"userIdentity": {"arn": "arn:aws:iam::123456789012:user/operator"}}),
                         "arn:aws:iam::123456789012:user/operator")
        self.assertEqual(remediation._actor({"userIdentity": {"invokedBy": "ec2.amazonaws.com"}}), "ec2.amazonaws.com")
        self.assertEqual(remediation._actor({"userIdentity": []}), "unknown")

    def test_slack_payload_only_operational_metadata(self):
        incoming = event()
        self.run_event(incoming)
        record = self.notify.call_args.args[0]
        response = Mock(status=200)
        response.read.return_value = b"ok"
        with patch.object(remediation.urllib.request, "urlopen") as urlopen:
            urlopen.return_value.__enter__.return_value = response
            remediation._notify(record)
            payload = json.loads(urlopen.call_args.args[0].data)
            self.assertIn(RULE_ID, payload["text"])
            self.assertNotIn("SECRET", payload["text"])
            self.assertEqual(urlopen.call_args.kwargs["timeout"], 3)

    def test_sdk_contract_without_network(self):
        client = boto3.client("ec2", region_name=CONFIG["TARGET_REGION"],
                              aws_access_key_id="testing", aws_secret_access_key="testing")
        with Stubber(client) as stubber:
            stubber.add_response("describe_security_groups", {"SecurityGroups": [group()]}, {"GroupIds": [GROUP_ID]})
            stubber.add_response("describe_security_group_rules", {"SecurityGroupRules": [rule()]},
                                 {"Filters": [{"Name": "group-id", "Values": [GROUP_ID]}]})
            stubber.add_response("describe_security_group_rules", {"SecurityGroupRules": [rule()]}, {"SecurityGroupRuleIds": [RULE_ID]})
            stubber.add_response("describe_security_groups", {"SecurityGroups": [group()]}, {"GroupIds": [GROUP_ID]})
            stubber.add_response("revoke_security_group_ingress", {"Return": True},
                                 {"GroupId": GROUP_ID, "SecurityGroupRuleIds": [RULE_ID]})
            self.assertEqual(remediation.remediate(event(), client, self.notify)["revoked"], 1)
            stubber.assert_no_pending_responses()


if __name__ == "__main__":
    unittest.main()
