#!/usr/bin/env python3
"""Render a Collector SA patch from Terraform JSON, without AWS or git calls."""
import argparse
import json
from pathlib import Path
import re
import sys


def render(value, environment):
    namespace = {"dev": "app", "prod": "app-prod"}[environment]
    if (not isinstance(value, dict) or value.get("environment") != environment
            or value.get("namespace") != namespace
            or value.get("service_account") != "adot-collector"
            or not re.fullmatch(r"[0-9]{12}", str(value.get("account_id", "")))
            or value.get("region") != "ap-northeast-2"
            or not isinstance(value.get("role_arn"), str)
            or not re.fullmatch(rf"arn:aws:iam::{value['account_id']}:role/[A-Za-z0-9_+=,.@-]+-{environment}-adot", value["role_arn"])):
        raise ValueError("Wrong tracing identity boundary")
    return ("# Generated from Terraform tracing_irsa_config.\n"
            "apiVersion: v1\nkind: ServiceAccount\nmetadata:\n  name: adot-collector\n"
            "  namespace: app\n  annotations:\n"
            f"    eks.amazonaws.com/role-arn: {json.dumps(value['role_arn'])}\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--environment", choices=["dev", "prod"], required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        patch = render(json.load(sys.stdin), args.environment)
    except (ValueError, TypeError, KeyError):
        sys.exit("Invalid tracing output; existing manifest preserved")
    path = args.output
    path.write_text(patch)
    print(f"Updated tracing identity patch: {path}")


if __name__ == "__main__":
    main()
