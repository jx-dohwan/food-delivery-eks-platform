"""Revalidate project ingress and revoke only rule IDs exposing public SSH."""
import ipaddress
import json
import logging
import os
import re
import urllib.request
from datetime import datetime

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

LOGGER = logging.getLogger(__name__)
LOGGER.setLevel(logging.INFO)
EVENT_NAMES = {"AuthorizeSecurityGroupIngress", "ModifySecurityGroupRules"}
SG_ID = re.compile(r"sg-(?:[0-9a-f]{8}|[0-9a-f]{17})\Z")
RULE_ID = re.compile(r"sgr-[0-9a-f]{17}\Z")
ABSENT = {"InvalidGroup.NotFound", "InvalidSecurityGroupRuleId.NotFound", "InvalidPermission.NotFound"}


def public_ssh_cidr(rule):
    if not isinstance(rule, dict) or rule.get("IsEgress") is not False:
        return None
    protocol = rule.get("IpProtocol")
    if protocol not in ("tcp", "6", "-1"):
        return None
    if protocol != "-1":
        start, end = rule.get("FromPort"), rule.get("ToPort")
        if type(start) is not int or type(end) is not int or not (0 <= start <= 22 <= end <= 65535):
            return None
    for key, version in (("CidrIpv4", 4), ("CidrIpv6", 6)):
        try:
            network = ipaddress.ip_network(rule.get(key, ""), strict=True)
            if network.version == version and network.prefixlen == 0:
                return str(network)
        except (ValueError, TypeError):
            continue
    return None


def _target_group(event):
    if not isinstance(event, dict):
        return None
    detail = event.get("detail")
    if not isinstance(detail, dict):
        return None
    if (event.get("source") != "aws.ec2"
            or event.get("detail-type") != "AWS API Call via CloudTrail"
            or event.get("account") != os.environ["ACCOUNT_ID"]
            or event.get("region") != os.environ["TARGET_REGION"]
            or detail.get("eventSource") != "ec2.amazonaws.com"
            or not isinstance(detail.get("eventName"), str)
            or detail.get("eventName") not in EVENT_NAMES
            or "errorCode" in detail):
        return None
    parameters = detail.get("requestParameters")
    group_id = parameters.get("groupId") if isinstance(parameters, dict) else None
    return group_id if isinstance(group_id, str) and SG_ID.fullmatch(group_id) else None


def _owned_group(ec2, group_id):
    response = ec2.describe_security_groups(GroupIds=[group_id])
    groups = response.get("SecurityGroups", [])
    if len(groups) != 1:
        return False
    group = groups[0]
    tags = {tag["Key"]: tag["Value"] for tag in group.get("Tags", [])}
    required = {"Project": os.environ["PROJECT_TAG"], "Environment": os.environ["ENV_TAG"],
                "ManagedBy": os.environ["MANAGED_BY_TAG"]}
    return (group.get("GroupId") == group_id and group.get("OwnerId") == os.environ["ACCOUNT_ID"]
            and group.get("VpcId") == os.environ["VPC_ID"] and group.get("GroupName") != "default"
            and all(tags.get(key) == value for key, value in required.items()))


def _actor(detail):
    identity = detail.get("userIdentity")
    if not isinstance(identity, dict):
        return "unknown"
    # Prefer the role ARN over potentially sensitive/custom session names.
    session = identity.get("sessionContext")
    issuer = session.get("sessionIssuer") if isinstance(session, dict) else None
    arn = issuer.get("arn") if isinstance(issuer, dict) else identity.get("arn")
    if isinstance(arn, str) and re.fullmatch(r"arn:aws:iam::[0-9]{12}:(?:user|role)/[A-Za-z0-9_+=,.@/-]{1,200}", arn):
        return arn
    service = identity.get("invokedBy")
    if isinstance(service, str) and re.fullmatch(r"[a-z0-9.-]+\.amazonaws\.com", service):
        return service
    return "unknown"


def _event_time(detail):
    try:
        return datetime.fromisoformat(detail.get("eventTime", "").replace("Z", "+00:00")).isoformat()
    except (ValueError, TypeError, AttributeError):
        return "unknown"


def _notify(record):
    payload = {"text": "[Security Group 자동 차단]\n" + "\n".join([
        f"Security Group: {record['group_id']}", f"Rule: {record['rule_id']}",
        f"Violation: Public SSH (22 포함 / {record['protocol']})",
        f"CIDR: {record['cidr']}", "Action: Rule revoked",
        f"Actor: {record['actor']}", f"Region: {record['region']}", f"Time: {record['time']}"
    ])}
    request = urllib.request.Request(os.environ["SLACK_WEBHOOK_URL"],
                                     data=json.dumps(payload).encode("utf-8"),
                                     headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(request, timeout=3) as response:
        if response.status != 200 or response.read(64).strip() != b"ok":
            raise RuntimeError("Notification rejected")


def remediate(event, ec2, notify=_notify):
    group_id = _target_group(event)
    if group_id is None:
        LOGGER.info('Ignored unsupported or malformed security group event')
        return {"status": "ignored", "revoked": 0}
    revoked = 0
    try:
        if not _owned_group(ec2, group_id):
            return {"status": "outside_project", "revoked": 0}
        pages = ec2.get_paginator("describe_security_group_rules").paginate(
            Filters=[{"Name": "group-id", "Values": [group_id]}])
        for page in pages:
            for candidate in page.get("SecurityGroupRules", []):
                rule_id = candidate.get("SecurityGroupRuleId")
                if not (isinstance(rule_id, str) and RULE_ID.fullmatch(rule_id) and public_ssh_cidr(candidate)):
                    continue
                # Re-fetch the exact current rule and tags immediately before revoke.
                # AWS has no atomic compare-and-revoke; the tiny remaining race is documented.
                try:
                    fresh = ec2.describe_security_group_rules(SecurityGroupRuleIds=[rule_id]).get("SecurityGroupRules", [])
                    if (len(fresh) != 1 or fresh[0].get("GroupId") != group_id
                            or fresh[0].get("SecurityGroupRuleId") != rule_id):
                        continue
                    current = fresh[0]
                    cidr = public_ssh_cidr(current)
                    if not cidr or not _owned_group(ec2, group_id):
                        continue
                    result = ec2.revoke_security_group_ingress(GroupId=group_id, SecurityGroupRuleIds=[rule_id])
                    if result.get("Return") is not True:
                        raise RuntimeError("Ingress revoke was not confirmed")
                except ClientError as error:
                    if error.response.get("Error", {}).get("Code") in ABSENT:
                        continue
                    raise
                revoked += 1
                record = {"action": "rule_revoked", "group_id": group_id, "rule_id": rule_id,
                          "cidr": cidr, "protocol": current["IpProtocol"], "actor": _actor(event["detail"]),
                          "region": os.environ["TARGET_REGION"], "time": _event_time(event["detail"])}
                LOGGER.info(json.dumps(record))
                try:
                    notify(record)
                except Exception:
                    # Never log webhook URL, response body, secret or exception text.
                    LOGGER.warning("Slack notification failed after successful rule revoke")
    except ClientError as error:
        if error.response.get("Error", {}).get("Code") not in ABSENT:
            LOGGER.error("Security group lookup or revoke failed; retry required")
            raise RuntimeError("Security group remediation failed") from None
    except Exception:
        LOGGER.error("Security group remediation failed; retry required")
        raise RuntimeError("Security group remediation failed") from None
    return {"status": "remediated" if revoked else "already_safe", "revoked": revoked}


def handler(event, context):
    if _target_group(event) is None:
        return {"status": "ignored", "revoked": 0}
    ec2 = boto3.client("ec2", region_name=os.environ["TARGET_REGION"],
                       config=Config(connect_timeout=3, read_timeout=10,
                                     retries={"mode": "standard", "total_max_attempts": 2}))
    return remediate(event, ec2)
