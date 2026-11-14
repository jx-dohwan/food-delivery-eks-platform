#!/usr/bin/env python3
"""Publish non-secret Terraform runtime_bindings into one environment overlay.

Local parsing only. No AWS, Terraform, kubectl, git or network operations.
"""
import argparse
import ipaddress
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
REGION = "ap-northeast-2"


def validate(value, environment):
    namespace = "app" if environment == "dev" else "app-prod"
    if (not isinstance(value, dict) or value.get("infrastructure_complete") is not True
            or value.get("environment") != environment or value.get("namespace") != namespace
            or not re.fullmatch(r"[0-9]{12}", str(value.get("account_id", ""))) or value.get("region") != REGION):
        raise ValueError("Runtime infrastructure is incomplete or outside the environment boundary")
    account = value["account_id"]
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,99}", str(value.get("cluster_name", ""))):
        raise ValueError("Missing cluster identity")
    if not re.fullmatch(r"sg-(?:[0-9a-f]{8}|[0-9a-f]{17})", str(value.get("alb_security_group_id", ""))):
        raise ValueError("Missing exact ALB security group ID")
    eso = value.get("eso")
    if not isinstance(eso, dict) or eso.get("service_account") != "eso-service-account":
        raise ValueError("Missing ESO identity")
    if not re.fullmatch(rf"arn:aws:iam::{account}:role/[A-Za-z0-9_+=,.@-]*external-secrets-role", str(eso.get("role_arn", ""))):
        raise ValueError("Wrong ESO role ARN")
    names = [eso.get("authentication_secret_name"), eso.get("connection_secret_name")]
    if any(not isinstance(n, str) or not re.fullmatch(r"[A-Za-z0-9/_+=.@-]{1,512}", n) for n in names) or names[1] != names[0] + "-connection":
        raise ValueError("Wrong application Secret names")
    if environment == "prod" and "prod-" not in names[0]:
        raise ValueError("Prod must not read dev Secrets")
    if not re.fullmatch(r"[a-z0-9-]+\.proxy-[a-z0-9-]+\.ap-northeast-2\.rds\.amazonaws\.com", str(value.get("db_proxy_endpoint", ""))):
        raise ValueError("DB endpoint must be a Seoul RDS Proxy endpoint")
    if not re.fullmatch(r"[a-z0-9.-]+\.cache\.amazonaws\.com", str(value.get("redis_endpoint", ""))):
        raise ValueError("Missing Redis endpoint")
    private_ranges = [ipaddress.ip_network(c) for c in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")]
    try:
        vpc = ipaddress.ip_network(value.get("vpc_cidr", ""), strict=True)
        if vpc.version != 4 or not any(vpc.subnet_of(n) for n in private_ranges):
            raise ValueError()
        subnets = []
        for key in ("public_subnet_cidrs", "private_subnet_cidrs"):
            items = value.get(key)
            if not isinstance(items, list) or not items:
                raise ValueError()
            for item in items:
                subnet = ipaddress.ip_network(item, strict=True)
                if subnet.version != 4 or subnet.prefixlen <= vpc.prefixlen or not subnet.subnet_of(vpc):
                    raise ValueError()
                subnets.append(subnet)
        if any(a.overlaps(b) for i, a in enumerate(subnets) for b in subnets[i+1:]):
            raise ValueError()
    except (TypeError, ValueError):
        raise ValueError("Invalid or overlapping runtime network ranges") from None
    # Current CI/bootstrap policy intentionally supports exactly these two repos.
    expected = {c: f"{account}.dkr.ecr.{REGION}.amazonaws.com/{c}" for c in ("was", "web")}
    if value.get("ecr_urls") != expected:
        raise ValueError("ECR repositories do not match the current SHA publishing contract")
    waf = value.get("waf")
    if not isinstance(waf, dict) or not isinstance(waf.get("enabled"), bool):
        raise ValueError("Missing explicit WAF state")
    if waf["enabled"]:
        pattern = rf"arn:aws:wafv2:{REGION}:{account}:regional/webacl/[A-Za-z0-9_-]+-{environment}-waf/[0-9a-fA-F-]{{36}}"
        if not re.fullmatch(pattern, str(waf.get("web_acl_arn", ""))):
            raise ValueError("Wrong environment/account WAF ARN")
    elif waf.get("web_acl_arn") is not None:
        raise ValueError("Disabled WAF must have a null ARN")


def runtime_resources(value, environment):
    validate(value, environment)
    eso = value["eso"]
    def resource(kind, name, **fields):
        return dict(apiVersion="external-secrets.io/v1" if kind in ("ExternalSecret", "SecretStore") else
                    "networking.k8s.io/v1" if kind == "Ingress" else "v1",
                    kind=kind, metadata=dict(name=name, namespace="app"), **fields)
    sa = resource("ServiceAccount", "eso-service-account")
    sa["metadata"]["annotations"] = {"eks.amazonaws.com/role-arn": eso["role_arn"]}
    raw = subprocess.check_output(["ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.load_file(ARGV[0]))",
                                   str(ROOT / "k8s/base/secrets/external-secret.yaml")], text=True, stderr=subprocess.DEVNULL)
    external = json.loads(raw)
    for item in external["spec"]["data"]:
        item["remoteRef"]["key"] = eso["connection_secret_name"] if item["secretKey"] in ("DB_HOST", "REDIS_HOST", "REDIS_PORT") else eso["authentication_secret_name"]
    store = resource("SecretStore", "aws-secrets-manager-store", spec={"provider": {"aws": {
        "service": "SecretsManager", "region": REGION,
        "auth": {"jwt": {"serviceAccountRef": {"name": eso["service_account"]}}}
    }}})
    config = resource("ConfigMap", "was-config", data={
        "DB_TLS": "true", "REDIS_TLS": "true",
        "RATE_LIMIT_ALB_PROXY_CIDRS": ",".join(value["public_subnet_cidrs"]),
        "RATE_LIMIT_WEB_PROXY_CIDRS": ",".join(value["private_subnet_cidrs"]),
    })
    ingress = resource("Ingress", "main-ingress")
    ingress["metadata"]["annotations"] = {"alb.ingress.kubernetes.io/security-groups": value["alb_security_group_id"]}
    # Dev retains its existing dedicated WAF output renderer as the patch owner.
    if environment == "prod":
        ingress["metadata"]["annotations"]["alb.ingress.kubernetes.io/wafv2-acl-arn"] = value["waf"]["web_acl_arn"] if value["waf"]["enabled"] else "none"
    return [sa, external, store, config, ingress]


def patches(value, environment):
    resources = runtime_resources(value, environment)
    return {
        "runtime-bindings-patch.yaml": "# Generated from non-secret runtime_bindings; no AWS calls.\n" + "\n---\n".join(json.dumps(r, indent=2) for r in resources) + "\n",
        "runtime-network-patch.json": json.dumps([{"op": "replace", "path": "/spec/egress/0/to/0/ipBlock/cidr", "value": value["vpc_cidr"]}], indent=2) + "\n",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--environment", choices=["dev", "prod"], required=True)
    # Explicit directory only: rendered values are account-specific and must never land in tracked files.
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    try:
        rendered = patches(json.load(sys.stdin), args.environment)
        for name, content in rendered.items():
            (args.output_dir / name).write_text(content)
    except (OSError, subprocess.SubprocessError, ValueError, TypeError, KeyError):
        sys.exit("Invalid runtime bindings; deploy remains blocked (no input values printed)")
    print("Updated local runtime binding patches; run pre-full-deploy before sync")


if __name__ == "__main__":
    main()
