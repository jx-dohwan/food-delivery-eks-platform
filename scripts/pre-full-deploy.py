#!/usr/bin/env python3
"""Offline application-deploy gate: Terraform outputs + GitOps + manual evidence.

Runs only local kustomize/Ruby parsers. Never invokes AWS, Terraform or kubectl;
never modifies manifests or prints credentials/input values.
"""
import argparse
import os
from datetime import datetime, timezone, timedelta
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
REQUIRED_CHECKS = (
    "state_and_account_reviewed", "addon_versions_verified", "cost_estimate_reviewed",
    "old_slack_webhook_revoked", "new_slack_webhook_configured", "application_resources_verified",
    "metrics_tls_verified", "collector_image_config_validated", "teardown_dry_run_reviewed", "ingress_certificate_verified", "image_build_verified",
)
SLACK_ROTATION_CHECKS = ("old_slack_webhook_revoked", "new_slack_webhook_configured")


def validate_slack_evidence(checks, environment, checked, now):
    """Default: rotate first. Explicit dev-only exception expires within 8 hours.

    This is operator evidence, not revocation or an automatic runtime stop.
    Never mark the rotation checks true on behalf of this exception.
    """
    if all(checks.get(key) is True for key in SLACK_ROTATION_CHECKS):
        return
    exception = checks.get("slack_test_exception")
    if environment != "dev" or not isinstance(exception, dict):
        raise ValueError("Slack rotation is required or an explicit short-lived dev test exception must be recorded")
    required = ("acknowledge_exposed_webhook", "test_only_notifications", "rotate_after_tests")
    if any(exception.get(key) is not True for key in required):
        raise ValueError("Slack dev test risk/scope/post-test rotation acknowledgements are incomplete")
    try:
        expires = datetime.fromisoformat(exception["expires_at"].replace("Z", "+00:00"))
        if not checked <= now < expires <= checked + timedelta(hours=8):
            raise ValueError()
    except (KeyError, TypeError, ValueError, AttributeError):
        raise ValueError("Slack dev test exception must have an unexpired timezone-aware deadline within 8 hours of evidence") from None


def load_module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_renderer(name):
    return load_module(name).render


def contains_fields(actual, expected):
    if isinstance(expected, dict):
        return isinstance(actual, dict) and all(k in actual and contains_fields(actual[k], v) for k, v in expected.items())
    return actual == expected


def validate_image_source(documents, environment, repo=ROOT):
    """Read-only local Git proof. GitOps/docs commits may follow the image source.

    Refuse old image code and uncommitted/untracked build inputs; never fetch or
    commit. Registry digest availability is a separate operator/runtime check.
    """
    namespace = "app" if environment == "dev" else "app-prod"
    was = next(r for r in documents if r.get("kind") == "Deployment" and r.get("metadata", {}).get("namespace") == namespace and r["metadata"].get("name") == "was-deployment")
    image = was["spec"]["template"]["spec"]["containers"][0]["image"]
    sha = image.rsplit(":", 1)[-1]
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("Missing image source SHA")
    command = ["git", "-C", str(repo)]
    paths = ["app", ".github/workflows/deploy.yml", "scripts/ci"]
    try:
        subprocess.run(command + ["cat-file", "-e", sha + "^{commit}"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(command + ["diff", "--quiet", "--no-ext-diff", "--no-textconv", sha, "--", *paths], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        untracked = subprocess.check_output(command + ["ls-files", "--others", "--exclude-standard", "--", *paths], stderr=subprocess.DEVNULL)
        if untracked:
            raise ValueError()
    except (OSError, subprocess.SubprocessError, ValueError):
        raise ValueError("Image source differs from current build inputs; commit and publish the current source before sync") from None


def unwrap(outputs, name):
    item = outputs.get(name)
    if not isinstance(item, dict) or item.get("sensitive") is not False:
        raise ValueError("Missing or sensitive Terraform output: " + name)
    return item.get("value")


def validate(outputs, checks, documents, environment, now=None):
    if not isinstance(outputs, dict):
        raise ValueError("Terraform outputs must be an object")
    was = unwrap(outputs, "was_irsa_config")
    collector = unwrap(outputs, "tracing_irsa_config")
    config = unwrap(outputs, "full_deploy_config")
    bindings = unwrap(outputs, "runtime_bindings")
    binding_resources = load_module("render-runtime-bindings").runtime_resources(bindings, environment)
    # Reuse the same strict identity/environment checks as the output renderers.
    load_renderer("render-workload-irsa")(was, environment)
    load_renderer("render-tracing-irsa")(collector, environment)
    if not isinstance(config, dict) or config.get("environment") != environment or config.get("region") != "ap-northeast-2":
        raise ValueError("Wrong Full Deploy environment/region")
    if not was.get("s3_bucket_name") or was.get("s3_encryption") != "AES256":
        raise ValueError("Verified application SSE-S3 bucket is required")
    sender, identity = was.get("ses_from_address"), was.get("ses_identity")
    if environment == "prod" and (not sender or identity not in (sender, sender.split("@")[-1])):
        raise ValueError("Verified SES identity/From is required")
    if was["s3_bucket_name"] in protected_state_buckets():
        raise ValueError("State bucket cannot be an application upload target")
    if config.get("metrics_server_tls_verified") is not True:
        raise ValueError("metrics-server TLS remains unverified; complete the certificate preflight")
    if not isinstance(checks, dict) or checks.get("environment") != environment:
        raise ValueError("Wrong manual-evidence environment")
    try:
        stamp = checks.get("checked_at")
        if not isinstance(stamp, str):
            raise ValueError()
        checked = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
        current = now or datetime.now(timezone.utc)
        age = current - checked
        if not timedelta(0) <= age <= timedelta(hours=24):
            raise ValueError()
    except (KeyError, TypeError, ValueError):
        raise ValueError("Manual preflight evidence must be dated within the last 24 hours") from None
    validate_slack_evidence(checks, environment, checked, current)
    for key in REQUIRED_CHECKS:
        if key in SLACK_ROTATION_CHECKS:
            continue
        if checks.get(key) is not True:
            raise ValueError("Required manual/runtime evidence missing: " + key)
    if environment == "prod" and checks.get("prod_state_storage_and_database_reviewed") is not True:
        raise ValueError("Prod state/storage/database remain deferred")
    karpenter = config.get("karpenter")
    if not isinstance(karpenter, dict) or not isinstance(karpenter.get("enabled"), bool):
        raise ValueError("Missing Karpenter state")
    if karpenter["enabled"] and (karpenter.get("verified") is not True
            or not re.fullmatch(r"ami-[0-9a-f]{17}", str(karpenter.get("ami_id", "")))
            or checks.get("karpenter_offerings_price_verified") is not True):
        raise ValueError("Karpenter AMI/offerings/price preflight is incomplete")
    namespace = "app" if environment == "dev" else "app-prod"
    resources = {(r["kind"], r.get("metadata", {}).get("namespace"), r.get("metadata", {}).get("name")): r for r in documents}
    for expected in binding_resources:
        expected["metadata"]["namespace"] = namespace
        actual = resources.get((expected["kind"], namespace, expected["metadata"]["name"]))
        if not contains_fields(actual, expected):
            raise ValueError("Runtime ESO/Secret/network/ALB bindings are missing or mismatched")
        if expected["kind"] in ("ExternalSecret", "SecretStore") and actual.get("spec") != expected["spec"]:
            raise ValueError("Unexpected ESO provider or Secret source override")
    ingress = resources.get(("Ingress", namespace, "main-ingress"), {})
    cert = ingress.get("metadata", {}).get("annotations", {}).get("alb.ingress.kubernetes.io/certificate-arn", "")
    if not re.fullmatch(rf"arn:aws:acm:ap-northeast-2:{bindings['account_id']}:certificate/[0-9a-f-]{{36}}", cert):
        raise ValueError("Ingress requires a verified same-account Seoul ACM certificate")
    waf = bindings["waf"]
    expected_acl = waf["web_acl_arn"] if waf["enabled"] else "none"
    if ingress.get("metadata", {}).get("annotations", {}).get("alb.ingress.kubernetes.io/wafv2-acl-arn") != expected_acl:
        raise ValueError("WAF Terraform state and Ingress association differ")
    for name in ("was-dependencies", "migration-database"):
        policy = resources.get(("NetworkPolicy", namespace, name), {})
        if policy.get("spec", {}).get("egress", [{}])[0].get("to", [{}])[0].get("ipBlock", {}).get("cidr") != bindings["vpc_cidr"]:
            raise ValueError("Database NetworkPolicy differs from the Terraform VPC")
    images = []
    for kind, name, component in (("Deployment", "was-deployment", "was"), ("Deployment", "web-deployment", "web"), ("Job", "was-db-migration", "was")):
        pod = resources.get((kind, namespace, name), {}).get("spec", {}).get("template", {}).get("spec", {})
        container = pod.get("containers", [{}])[0]
        match = re.fullmatch(re.escape(bindings["ecr_urls"][component]) + r":([0-9a-f]{40})", str(container.get("image", "")))
        if not match:
            raise ValueError("Workload image must use its exact ECR repository and immutable SHA")
        images.append(match[1])
        if component == "was":
            if pod.get("containers", [{}])[0].get("envFrom") != [{"configMapRef": {"name": "was-config"}}, {"secretRef": {"name": "was-db-secret"}}]:
                raise ValueError("WAS/Migration must consume the ESO-managed Secret")
            if any(v.get("name", "").startswith(("DB_", "REDIS_", "JWT_")) for v in container.get("env", [])):
                raise ValueError("Inline environment may not override the application Secret")
            if environment == "dev" and any(v.get("name") in {"AWS_SES_SENDER_EMAIL", "SKIP_EMAIL_NOTIFICATION"}
                                             for v in container.get("env", [])):
                raise ValueError("Dev email configuration may not be overridden by inline environment")
    if len(set(images)) != 1:
        raise ValueError("WAS/Web/Migration image SHAs differ")
    for value in (was, collector):
        sa = resources.get(("ServiceAccount", namespace, value["service_account"]), {})
        if sa.get("metadata", {}).get("annotations", {}).get("eks.amazonaws.com/role-arn") != value["role_arn"]:
            raise ValueError("Rendered ServiceAccount role is missing/placeholder/mismatched")
    pod = resources.get(("Deployment", namespace, "was-deployment"), {}).get("spec", {}).get("template", {}).get("spec", {})
    if pod.get("serviceAccountName") != was["service_account"]:
        raise ValueError("WAS ServiceAccount mismatch")
    pod = resources.get(("Deployment", namespace, "adot-collector"), {}).get("spec", {}).get("template", {}).get("spec", {})
    if pod.get("serviceAccountName") != collector["service_account"]:
        raise ValueError("Collector ServiceAccount mismatch")
    data = resources.get(("ConfigMap", namespace, "was-config"), {}).get("data", {})
    expected = {"AWS_REGION": "ap-northeast-2", "AWS_S3_BUCKET_NAME": was["s3_bucket_name"],
                "OTEL_TRACES_EXPORTER": "otlp", "OTEL_METRICS_EXPORTER": "none", "OTEL_LOGS_EXPORTER": "none",
                "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": "http://adot-collector:4318/v1/traces"}
    expected.update(load_module("render-workload-irsa").email_configuration(was, environment))
    if any(data.get(k) != v for k, v in expected.items()):
        raise ValueError("Rendered WAS AWS/tracing configuration does not match Terraform outputs")


def protected_state_buckets():
    """The state bucket name is private: environment first, then the git-ignored target."""
    name = os.environ.get("FOOD_DELIVERY_STATE_BUCKET", "")
    if not name:
        try:
            target = json.loads((Path(__file__).resolve().parents[1] / "config/r2-dev-target.json").read_text())
            name = (target.get("archive_backend") or {}).get("bucket", "")
        except (OSError, ValueError, AttributeError):
            name = ""
    if not name:
        raise ValueError("State bucket identity is not configured (FOOD_DELIVERY_STATE_BUCKET or private target)")
    return {name}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--environment", choices=["dev", "prod"], required=True)
    parser.add_argument("--outputs-file", type=Path, required=True)
    parser.add_argument("--checks-file", type=Path, required=True)
    parser.add_argument("--kustomize", default="kustomize")
    args = parser.parse_args()
    try:
        outputs = json.loads(args.outputs_file.read_text())
        checks = json.loads(args.checks_file.read_text())
        yaml = subprocess.check_output([args.kustomize, "build", str(ROOT / "k8s/overlays" / args.environment)], text=True, stderr=subprocess.DEVNULL)
        docs = json.loads(subprocess.check_output(["ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.load_stream(STDIN.read).compact)"], input=yaml, text=True, stderr=subprocess.DEVNULL))
        validate(outputs, checks, docs, args.environment)
        validate_image_source(docs, args.environment)
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError, AttributeError, IndexError) as error:
        # Only our controlled validation messages may be printed, never a parser,
        # tool exception or file's raw content (which could contain credentials).
        safe = str(error) if type(error) is ValueError else "Invalid/missing preflight input or local render failed"
        if isinstance(error, json.JSONDecodeError):
            safe = "Invalid preflight JSON"
        sys.exit("APPLICATION PREFLIGHT BLOCKED: " + safe)
    if not all(checks.get(key) is True for key in SLACK_ROTATION_CHECKS):
        print("WARNING: short-lived dev Slack test exception; rotation and new-webhook delivery verification remain mandatory after tests")
    print("APPLICATION PREFLIGHT PASS: local configuration and operator evidence agree; runtime acceptance is still required")


if __name__ == "__main__":
    main()
