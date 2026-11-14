#!/usr/bin/env python3
"""Read Terraform was_irsa_config JSON on stdin; write one GitOps overlay patch.

No AWS, terraform, kubectl, git or network commands are invoked.
"""
import argparse
import json
from pathlib import Path
import re
import sys


def email_configuration(value, environment):
    """Dev never sends mail. Production retains its existing sender-based policy."""
    if environment == "dev":
        return {"AWS_SES_SENDER_EMAIL": "", "SKIP_EMAIL_NOTIFICATION": "true"}
    sender = value.get("ses_from_address", "")
    return {"AWS_SES_SENDER_EMAIL": sender, "SKIP_EMAIL_NOTIFICATION": "false" if sender else "true"}


def render(value, environment):
    namespace = {"dev": "app", "prod": "app-prod"}[environment]
    if (not isinstance(value, dict) or value.get("environment") != environment
            or value.get("namespace") != namespace
            or value.get("service_account") != "food-delivery-was"
            or not re.fullmatch(r"[0-9]{12}", str(value.get("account_id", "")))
            or value.get("region") != "ap-northeast-2"):
        raise ValueError("Wrong environment/account/region/ServiceAccount")
    arn = value.get("role_arn", "")
    if not isinstance(arn, str) or not re.fullmatch(
            rf"arn:aws:iam::{value['account_id']}:role/[A-Za-z0-9_+=,.@-]+-{environment}-was", arn):
        raise ValueError("Wrong WAS role ARN")
    bucket, sender = value.get("s3_bucket_name"), value.get("ses_from_address")
    if not isinstance(bucket, str) or (bucket and not re.fullmatch(r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]", bucket)):
        raise ValueError("Invalid bucket")
    if not isinstance(sender, str) or (sender and not re.fullmatch(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", sender)):
        raise ValueError("Invalid sender")
    email = email_configuration(value, environment)
    # Kustomize supplies the namespace. IAM trust has already selected app/app-prod.
    return ("# Generated from Terraform was_irsa_config; publish with the matching overlay.\n"
            "apiVersion: v1\nkind: ServiceAccount\nmetadata:\n  name: food-delivery-was\n  namespace: app\n  annotations:\n"
            f"    eks.amazonaws.com/role-arn: {json.dumps(arn)}\n"
            "---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: was-config\n  namespace: app\ndata:\n"
            f"  AWS_REGION: {json.dumps(value['region'])}\n"
            f"  AWS_S3_BUCKET_NAME: {json.dumps(bucket)}\n"
            f"  AWS_SES_SENDER_EMAIL: {json.dumps(email['AWS_SES_SENDER_EMAIL'])}\n"
            f"  SKIP_EMAIL_NOTIFICATION: {json.dumps(email['SKIP_EMAIL_NOTIFICATION'])}\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--environment", choices=["dev", "prod"], required=True)
    # Explicit path only: rendered values are account-specific and must never land in tracked files.
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        patch = render(json.load(sys.stdin), args.environment)
    except (ValueError, TypeError, KeyError):
        sys.exit("Invalid workload IRSA output; manifest left unchanged")
    path = args.output
    path.write_text(patch)
    print(f"Updated workload IRSA patch: {path}")


if __name__ == "__main__":
    main()
