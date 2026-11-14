#!/usr/bin/env python3
"""Render the dev or prod ArgoCD Application with every account-specific value injected at deploy time.

Git keeps only placeholders in k8s/overlays/<env>. This script reads `terraform output -json`
(file or stdin) plus the private, git-ignored target (config/r2-dev-target.json for dev,
config/prod-target.json for prod), reuses the existing
renderers' validation, and writes one Application whose spec.source.kustomize carries:
  - images:  registry override only, "name=registry/repo:*" (CI keeps writing the SHA tag to Git)
  - patches: IRSA / ESO / WAF / ALB SG / ingress host+certificate / BASE_URL

The output contains the account ID, so it must be written outside the repository or to a
git-ignored path. No AWS, Terraform, kubectl, git or network operations are performed.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
ENVIRONMENTS = {
    "dev": {"overlay": "k8s/overlays/dev", "template": "argocd-app.yaml", "target": "config/r2-dev-target.json"},
    "prod": {"overlay": "k8s/overlays/prod", "template": "argocd-app-prod.yaml", "target": "config/prod-target.json"},
}
IMAGES = ("was", "web")


def renderer(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), ROOT / "scripts" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def yaml_scalar(value):
    return json.dumps(value)


def ingress_patch(hosts, certificate_arn):
    rule = ("      http:\n        paths:\n          - path: /\n            pathType: Prefix\n"
            "            backend:\n              service:\n                name: nginx-service\n                port:\n                  number: 80\n")
    return ("apiVersion: networking.k8s.io/v1\nkind: Ingress\nmetadata:\n  name: main-ingress\n  namespace: app\n"
            f"  annotations:\n    alb.ingress.kubernetes.io/certificate-arn: {yaml_scalar(certificate_arn)}\n"
            "spec:\n  rules:\n" + "".join(f"    - host: {yaml_scalar(host)}\n" + rule for host in hosts))


def base_url_patch(host):
    return ("apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: was-config\n  namespace: app\ndata:\n"
            f"  BASE_URL: {yaml_scalar('https://' + host)}\n")


DOMAIN = re.compile(r"(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}")


def identity_patches(environment, target):
    """Owner-specific values that never came from Terraform: ingress hosts/certificate and BASE_URL."""
    account = target.get("account_id", "")
    if not re.fullmatch(r"[0-9]{12}", str(account)):
        raise ValueError("Private target needs a 12-digit account_id")
    certificate = target.get("ingress_certificate_arn", "")
    if not re.fullmatch(rf"arn:aws:acm:{re.escape(target['region'])}:{account}:certificate/[0-9a-f-]{{36}}", certificate):
        raise ValueError("ingress_certificate_arn must be an ACM certificate in the target account/region")
    if environment == "dev":
        hosts = [target["dev_variables"]["dev_domain_name"]]
        selector = {}
    else:
        hosts = [target["www_domain_name"], target["apex_domain_name"]]
        if not hosts[0].endswith("." + hosts[1]):
            raise ValueError("www_domain_name must be a subdomain of apex_domain_name")
        selector = {"ingress": {"kind": "Ingress", "name": "main-ingress"}, "config": {"kind": "ConfigMap", "name": "was-config"}}
    if not all(isinstance(h, str) and DOMAIN.fullmatch(h) for h in hosts):
        raise ValueError("Invalid domain in private target")
    return [dict({"patch": ingress_patch(hosts, certificate)}, **({"target": selector["ingress"]} if selector else {})),
            dict({"patch": base_url_patch(hosts[0])}, **({"target": selector["config"]} if selector else {}))], hosts[0]


def build(outputs, target, template_text, environment="dev"):
    env = ENVIRONMENTS[environment]
    value = lambda key: outputs[key]["value"]
    runtime = value("runtime_bindings")
    account = runtime.get("account_id")
    if account != target.get("account_id") or target.get("environment", environment) != environment:
        raise ValueError("Terraform outputs belong to a different account/environment than the private target")
    for key in ("was_irsa_config", "tracing_irsa_config"):
        if value(key).get("account_id") != account:
            raise ValueError("IRSA outputs disagree on the account")
    identity, host = identity_patches(environment, target)

    runtime_files = renderer("render-runtime-bindings").patches(runtime, environment)
    documents = [
        renderer("render-workload-irsa").render(value("was_irsa_config"), environment),
        renderer("render-tracing-irsa").render(value("tracing_irsa_config"), environment),
    ]
    if environment == "dev":  # prod carries its WAF annotation inside the runtime Ingress resource
        documents.append(renderer("render-waf-ingress").render(value("waf_ingress_config")))
    documents.append(runtime_files["runtime-bindings-patch.yaml"])
    capture = target.get("dev_email_capture_address_sha256") if environment == "dev" else None
    if capture is not None:
        if not re.fullmatch(r"[0-9a-f]{64}", str(capture)):
            raise ValueError("dev_email_capture_address_sha256 must be a lowercase SHA-256 hex digest")
        documents.append("apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: was-config\n  namespace: app\ndata:\n"
                         f"  DEV_EMAIL_CAPTURE_ADDRESS_SHA256: {yaml_scalar(capture)}\n"
                         # Replaces the domain that used to be hardcoded in dev-email-capture.service.ts.
                         f"  DEV_EMAIL_CAPTURE_ORIGIN: {yaml_scalar('https://' + host)}\n")
    patches = [{"patch": doc} for doc in documents] + identity
    patches.append({"patch": runtime_files["runtime-network-patch.json"],
                    "target": {"kind": "NetworkPolicy", "name": "(was-dependencies|migration-database)"}})
    urls = runtime["ecr_urls"]
    # ":*" keeps the SHA tag CI commits to Git; a bare name=newName would drop it (kustomize edit set image).
    images = [f"food-delivery-{c}={urls[c]}:*" for c in IMAGES]

    if "kustomize:" in template_text or "\n  source:\n" not in template_text:
        raise ValueError("Unexpected Application template shape")
    lines = template_text.rstrip("\n").split("\n")
    at = lines.index("    path: " + env["overlay"]) + 1
    block = ["    kustomize:", "      # Injected at deploy time; never committed.", "      images:"]
    block += [f"        - {yaml_scalar(i)}" for i in images]
    block += ["      patches:"]
    for p in patches:
        block.append(f"        - patch: {yaml_scalar(p['patch'])}")
        if "target" in p:
            block.append("          target:")
            block += [f"            {k}: {yaml_scalar(v)}" for k, v in p["target"].items()]
    return "\n".join(lines[:at] + block + lines[at:]) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--environment", choices=sorted(ENVIRONMENTS), default="dev")
    parser.add_argument("--outputs", type=Path, help="terraform output -json file (default: stdin)")
    parser.add_argument("--target", type=Path, help="private target (default per environment)")
    parser.add_argument("--template", type=Path, help="Application template (default per environment)")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        outputs = json.loads(args.outputs.read_text() if args.outputs else sys.stdin.read())
        env = ENVIRONMENTS[args.environment]
        target = json.loads((args.target or ROOT / env["target"]).read_text())
        template = (args.template or ROOT / env["template"]).read_text()
        rendered = build(outputs, target, template, args.environment)
    except (OSError, ValueError, TypeError, KeyError):
        sys.exit("Invalid Terraform outputs or private target; Application not rendered (no values printed)")
    out = args.output.resolve()
    if out.is_relative_to(ROOT.resolve()) and not _ignored(out):
        sys.exit("Refusing to write account-specific output to a tracked path")
    out.write_text(rendered)
    print(f"Rendered Application: {out}")


def _ignored(path):
    import subprocess
    return subprocess.run(["git", "-C", str(ROOT), "check-ignore", "-q", str(path)]).returncode == 0


if __name__ == "__main__":
    main()
