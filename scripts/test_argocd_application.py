#!/usr/bin/env python3
"""Deploy-time injection keeps Git free of account values and still renders the same workloads."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("render_argocd_application", ROOT / "scripts/render-argocd-application.py")
app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(app)

ACCOUNT = "123456789012"  # synthetic
REGISTRY = f"{ACCOUNT}.dkr.ecr.ap-northeast-2.amazonaws.com"
WAF = f"arn:aws:wafv2:ap-northeast-2:{ACCOUNT}:regional/webacl/food-delivery-dev-waf/00000000-0000-0000-0000-000000000001"


def outputs():
    runtime = {
        "infrastructure_complete": True, "environment": "dev", "namespace": "app", "account_id": ACCOUNT,
        "region": "ap-northeast-2", "cluster_name": "cluster", "vpc_cidr": "10.0.0.0/16",
        "public_subnet_cidrs": ["10.0.1.0/24", "10.0.2.0/24"], "private_subnet_cidrs": ["10.0.11.0/24", "10.0.12.0/24"],
        "alb_security_group_id": "sg-0123456789abcdef0",
        "eso": {"service_account": "eso-service-account", "role_arn": f"arn:aws:iam::{ACCOUNT}:role/external-secrets-role",
                "authentication_secret_name": "rds-aurora-credentials",
                "connection_secret_name": "rds-aurora-credentials-connection"},
        "db_proxy_endpoint": "cluster-proxy.proxy-abc123.ap-northeast-2.rds.amazonaws.com",
        "redis_endpoint": "master.cluster-redis.abc123.apn2.cache.amazonaws.com",
        "ecr_urls": {"was": f"{REGISTRY}/was", "web": f"{REGISTRY}/web"},
        "waf": {"enabled": True, "web_acl_arn": WAF},
    }
    was = {"environment": "dev", "namespace": "app", "service_account": "food-delivery-was", "account_id": ACCOUNT,
           "region": "ap-northeast-2", "role_arn": f"arn:aws:iam::{ACCOUNT}:role/cluster-dev-was",
           "s3_bucket_name": "food-delivery-dev-uploads-example", "ses_from_address": ""}
    tracing = {"environment": "dev", "namespace": "app", "service_account": "adot-collector", "account_id": ACCOUNT,
               "region": "ap-northeast-2", "role_arn": f"arn:aws:iam::{ACCOUNT}:role/cluster-dev-adot"}
    waf = {"environment": "dev", "enabled": True, "web_acl_arn": WAF}
    return {k: {"value": v} for k, v in {"runtime_bindings": runtime, "was_irsa_config": was,
                                         "tracing_irsa_config": tracing, "waf_ingress_config": waf}.items()}


def target():
    return json.loads((ROOT / "config/r2-dev-target.example.json").read_text())


def prod_outputs():
    o = outputs()
    r = o["runtime_bindings"]["value"]
    r.update(environment="prod", namespace="app-prod")
    r["eso"].update(authentication_secret_name="prod-rds-aurora-credentials",
                    connection_secret_name="prod-rds-aurora-credentials-connection")
    r["waf"] = {"enabled": True, "web_acl_arn": WAF.replace("-dev-waf", "-prod-waf")}
    o["was_irsa_config"]["value"].update(environment="prod", namespace="app-prod", s3_bucket_name="food-delivery-prod-uploads-example",
                                         role_arn=f"arn:aws:iam::{ACCOUNT}:role/cluster-prod-was", ses_from_address="sender@example.com")
    o["tracing_irsa_config"]["value"].update(environment="prod", namespace="app-prod", role_arn=f"arn:aws:iam::{ACCOUNT}:role/cluster-prod-adot")
    del o["waf_ingress_config"]
    return o


def prod_target():
    return json.loads((ROOT / "config/prod-target.example.json").read_text())


class RenderTests(unittest.TestCase):
    def render(self, out=None, tgt=None):
        return yaml.safe_load(app.build(out or outputs(), tgt or target(), (ROOT / "argocd-app.yaml").read_text()))

    def test_application_keeps_git_contract_and_adds_only_kustomize(self):
        rendered = self.render()
        original = yaml.safe_load((ROOT / "argocd-app.yaml").read_text())
        source = rendered["spec"]["source"]
        kustomize = source.pop("kustomize")
        self.assertEqual(rendered, original)
        self.assertEqual(source["targetRevision"], "main")
        self.assertEqual(kustomize["images"], [f"food-delivery-was={REGISTRY}/was:*", f"food-delivery-web={REGISTRY}/web:*"])

    def test_cross_account_inputs_are_rejected(self):
        for mutate in [lambda o, t: t.update(account_id="999999999999"),
                       lambda o, t: o["was_irsa_config"]["value"].update(account_id="999999999999"),
                       lambda o, t: t.update(ingress_certificate_arn=t["ingress_certificate_arn"].replace(ACCOUNT, "999999999999")),
                       lambda o, t: t.update(dev_email_capture_address_sha256="not-a-digest")]:
            o, t = outputs(), target()
            mutate(o, t)
            with self.subTest(), self.assertRaises(ValueError):
                app.build(o, t, (ROOT / "argocd-app.yaml").read_text())

    def test_tracked_paths_are_refused(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / "outputs.json").write_text(json.dumps(outputs()))
            result = subprocess.run(["python3", str(ROOT / "scripts/render-argocd-application.py"),
                                     "--outputs", str(Path(d) / "outputs.json"),
                                     "--target", str(ROOT / "config/r2-dev-target.example.json"),
                                     "--output", str(ROOT / "argocd-app.yaml")], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("tracked path", result.stderr)

    def test_git_overlay_holds_only_placeholders(self):
        build = subprocess.check_output([os.environ.get("KUSTOMIZE_BIN", "kustomize"), "build", str(ROOT / "k8s/overlays/dev")], text=True)
        self.assertIn("ecr-registry.invalid/was:", build)
        self.assertIn("arn:aws:iam::000000000000:role/injected-at-deploy-was", build)
        self.assertNotRegex(build, r"\b(?!000000000000|123456789012)\d{12}\b(?=[:.])")

    @unittest.skipUnless(os.environ.get("KUSTOMIZE_BIN") or shutil.which("kustomize"), "kustomize not installed")
    def test_injected_build_replaces_every_placeholder(self):
        kustomize = os.environ.get("KUSTOMIZE_BIN") or shutil.which("kustomize")
        kz = self.render()["spec"]["source"]["kustomize"]
        with tempfile.TemporaryDirectory() as d:
            shutil.copytree(ROOT / "k8s", Path(d) / "k8s")
            overlay = Path(d) / "k8s/overlays/dev"
            doc = yaml.safe_load((overlay / "kustomization.yaml").read_text())
            sha = {i["name"]: i["newTag"] for i in doc["images"]}
            doc["patches"] = doc["patches"] + kz["patches"]
            (overlay / "kustomization.yaml").write_text(yaml.safe_dump(doc, sort_keys=False))
            subprocess.run([kustomize, "edit", "set", "image", *kz["images"]], cwd=overlay, check=True)  # as ArgoCD does
            build = subprocess.check_output([kustomize, "build", str(overlay)], text=True)
        for placeholder in ["ecr-registry.invalid", ":000000000000:", "injected-at-deploy", "domain.invalid"]:
            self.assertNotIn(placeholder, build)
        self.assertIn(f"{REGISTRY}/was:{sha['food-delivery-was']}", build)
        self.assertIn(f"{REGISTRY}/web:{sha['food-delivery-web']}", build)
        self.assertIn(WAF, build)
        self.assertIn("host: dev.example.com", build)


class ProdRenderTests(unittest.TestCase):
    def test_prod_uses_its_own_template_overlay_and_two_hosts(self):
        rendered = yaml.safe_load(app.build(prod_outputs(), prod_target(), (ROOT / "argocd-app-prod.yaml").read_text(), "prod"))
        source = rendered["spec"]["source"]
        self.assertEqual(source["path"], "k8s/overlays/prod")
        text = json.dumps(source["kustomize"])
        self.assertIn("www.example.com", text)
        self.assertIn("\\\"example.com\\\"", text)
        self.assertIn(f"food-delivery-was={REGISTRY}/was:*", source["kustomize"]["images"])

    def test_prod_rejects_dev_target_and_unrelated_domains(self):
        with self.assertRaises((ValueError, KeyError)):
            app.build(prod_outputs(), target(), (ROOT / "argocd-app-prod.yaml").read_text(), "prod")
        bad = dict(prod_target(), www_domain_name="www.unrelated.test")
        with self.assertRaises(ValueError):
            app.build(prod_outputs(), bad, (ROOT / "argocd-app-prod.yaml").read_text(), "prod")

    @unittest.skipUnless(os.environ.get("KUSTOMIZE_BIN") or shutil.which("kustomize"), "kustomize not installed")
    def test_prod_injected_build_replaces_every_placeholder(self):
        kustomize = os.environ.get("KUSTOMIZE_BIN") or shutil.which("kustomize")
        kz = yaml.safe_load(app.build(prod_outputs(), prod_target(), (ROOT / "argocd-app-prod.yaml").read_text(), "prod"))["spec"]["source"]["kustomize"]
        with tempfile.TemporaryDirectory() as d:
            shutil.copytree(ROOT / "k8s", Path(d) / "k8s")
            overlay = Path(d) / "k8s/overlays/prod"
            doc = yaml.safe_load((overlay / "kustomization.yaml").read_text())
            doc["patches"] = doc["patches"] + kz["patches"]
            (overlay / "kustomization.yaml").write_text(yaml.safe_dump(doc, sort_keys=False))
            subprocess.run([kustomize, "edit", "set", "image", *kz["images"]], cwd=overlay, check=True)
            build = subprocess.check_output([kustomize, "build", str(overlay)], text=True)
        for placeholder in ["ecr-registry.invalid", ":000000000000:", "domain.invalid", 'role-arn: ""']:
            self.assertNotIn(placeholder, build)
        self.assertIn("host: www.example.com", build)
        self.assertIn("host: example.com", build)
        self.assertIn("namespace: app-prod", build)


if __name__ == "__main__":
    unittest.main()
