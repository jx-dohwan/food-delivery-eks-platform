"""No AWS, Terraform backend, Slack or cluster calls. Real local render only."""
import copy
from datetime import datetime, timezone, timedelta
import importlib.util
import json
import os
from pathlib import Path
import shutil
import re
import subprocess
import tempfile
import unittest
import os

os.environ.setdefault("FOOD_DELIVERY_STATE_BUCKET", "example-terraform-state-bucket")

ROOT = Path(__file__).resolve().parents[1]


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / (name + ".py"))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


gate = module("pre-full-deploy")
scanner = module("audit-commit-secrets")
NOW = datetime(2026, 10, 17, 6, tzinfo=timezone.utc)


def fixtures(environment="dev"):
    namespace = "app" if environment == "dev" else "app-prod"
    base = dict(environment=environment, namespace=namespace, account_id="123456789012", region="ap-northeast-2")
    was = dict(base, service_account="food-delivery-was", role_arn=f"arn:aws:iam::123456789012:role/test-{environment}-was",
               s3_bucket_name=f"food-{environment}-test-assets", s3_encryption="AES256", ses_identity="example.com", ses_from_address="sender@example.com")
    collector = dict(base, service_account="adot-collector", role_arn=f"arn:aws:iam::123456789012:role/test-{environment}-adot")
    bindings = dict(base, infrastructure_complete=True, cluster_name=f"test-{environment}-cluster", vpc_cidr="10.0.0.0/16",
                    public_subnet_cidrs=["10.0.0.0/24", "10.0.1.0/24", "10.0.2.0/24"],
                    private_subnet_cidrs=["10.0.10.0/24", "10.0.11.0/24", "10.0.12.0/24"],
                    alb_security_group_id="sg-00000000000000001", eso={
                        "role_arn": f"arn:aws:iam::123456789012:role/test-{environment}-external-secrets-role",
                        "service_account": "eso-service-account", "authentication_secret_name": f"test-{environment}-rds-aurora-credentials",
                        "connection_secret_name": f"test-{environment}-rds-aurora-credentials-connection"},
                    db_proxy_endpoint="test.proxy-example.ap-northeast-2.rds.amazonaws.com",
                    redis_endpoint="test.example.apn2.cache.amazonaws.com",
                    ecr_urls={c: f"123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/{c}" for c in ("was", "web")},
                    waf={"enabled": False, "web_acl_arn": None})
    outputs = {name: {"sensitive": False, "value": value} for name, value in {
        "was_irsa_config": was, "tracing_irsa_config": collector, "runtime_bindings": bindings,
        "full_deploy_config": dict(environment=environment, region="ap-northeast-2", metrics_server_tls_verified=True,
                                   karpenter=dict(enabled=True, ami_id="ami-0123456789abcdef0", verified=True)),
    }.items()}
    checks = dict.fromkeys(gate.REQUIRED_CHECKS, True)
    checks.update(environment=environment, checked_at=NOW.isoformat(), karpenter_offerings_price_verified=True,
                  prod_state_storage_and_database_reviewed=True)
    return outputs, checks


def bind_certificate(overlay, account="123456789012"):
    """Git keeps placeholders; emulate the deploy-time injection (ACM account and ECR registry).
    The registry uses the same `kustomize edit set image name=repo:*` call ArgoCD makes, keeping the SHA tag."""
    path = overlay / "ingress-patch.yaml"
    path.write_text(re.sub(r"(arn:aws:acm:[a-z0-9-]+:)[0-9]{12}(:certificate/)", rf"\g<1>{account}\2", path.read_text()))
    registry = f"{account}.dkr.ecr.ap-northeast-2.amazonaws.com"
    subprocess.run([os.environ.get("KUSTOMIZE_BIN", "kustomize"), "edit", "set", "image",
                    f"food-delivery-was={registry}/was:*", f"food-delivery-web={registry}/web:*"], cwd=overlay, check=True)


class PreFullDeployTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.repo = Path(cls.temp.name)
        shutil.copytree(ROOT / "k8s", cls.repo / "k8s")
        cls.docs = {}
        for environment in ("dev", "prod"):
            outputs, _ = fixtures(environment)
            overlay = cls.repo / "k8s/overlays" / environment
            for renderer, output, name in [("render-workload-irsa", "was_irsa_config", "was-irsa-patch.yaml"),
                                            ("render-tracing-irsa", "tracing_irsa_config", "tracing-irsa-patch.yaml")]:
                (overlay / name).write_text(module(renderer).render(outputs[output]["value"], environment))
            for name, content in module("render-runtime-bindings").patches(outputs["runtime_bindings"]["value"], environment).items():
                (overlay / name).write_text(content)
            if environment == 'dev':
                (overlay / 'waf-patch.yaml').write_text(module('render-waf-ingress').render(dict(environment='dev', **outputs['runtime_bindings']['value']['waf'])))
            bind_certificate(overlay)
            yaml = subprocess.check_output([os.environ.get("KUSTOMIZE_BIN", "kustomize"), "build", str(overlay)], text=True)
            cls.docs[environment] = json.loads(subprocess.check_output(
                ["ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.load_stream(STDIN.read).compact)"], input=yaml, text=True))

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_real_renderer_to_kustomize_to_gate_chain_both_environments(self):
        for environment in ("dev", "prod"):
            outputs, checks = fixtures(environment)
            gate.validate(outputs, checks, self.docs[environment], environment, NOW)

    def test_missing_or_placeholder_arns_fail_closed(self):
        for output in ("was_irsa_config", "tracing_irsa_config"):
            for arn in ("", "PLACEHOLDER", "arn:aws:iam::111111111111:role/test-dev-was"):
                outputs, checks = fixtures()
                outputs[output]["value"]["role_arn"] = arn
                with self.assertRaises(ValueError):
                    gate.validate(outputs, checks, self.docs["dev"], "dev", NOW)

    def test_application_resources_must_be_configured_and_match_manifest(self):
        for key in ("s3_bucket_name", "s3_encryption"):
            outputs, checks = fixtures()
            outputs["was_irsa_config"]["value"][key] = ""
            with self.assertRaises(ValueError):
                gate.validate(outputs, checks, self.docs["dev"], "dev", NOW)
        outputs, checks = fixtures()
        docs = copy.deepcopy(self.docs["dev"])
        sa = next(d for d in docs if d["kind"] == "ServiceAccount" and d["metadata"]["name"] == "adot-collector")
        sa["metadata"]["annotations"]["eks.amazonaws.com/role-arn"] = ""
        with self.assertRaises(ValueError):
            gate.validate(outputs, checks, docs, "dev", NOW)

    def test_dev_no_sender_is_valid_but_prod_ses_identity_stays_mandatory(self):
        outputs, checks = fixtures()
        outputs['was_irsa_config']['value'].update(ses_identity='', ses_from_address='')
        gate.validate(outputs, checks, self.docs['dev'], 'dev', NOW)
        for key in ('ses_identity', 'ses_from_address'):
            prod_outputs, prod_checks = fixtures('prod')
            prod_outputs['was_irsa_config']['value'][key] = ''
            with self.assertRaises(ValueError):
                gate.validate(prod_outputs, prod_checks, self.docs['prod'], 'prod', NOW)

    def test_dev_enabled_sender_or_inline_email_override_is_rejected(self):
        for field, bad in [('SKIP_EMAIL_NOTIFICATION', 'false'),
                           ('AWS_SES_SENDER_EMAIL', 'sender@example.com')]:
            outputs, checks = fixtures()
            docs = copy.deepcopy(self.docs['dev'])
            config = next(d for d in docs if d['kind'] == 'ConfigMap' and d['metadata']['name'] == 'was-config')
            config['data'][field] = bad
            with self.assertRaises(ValueError):
                gate.validate(outputs, checks, docs, 'dev', NOW)
            for name in ('was-deployment', 'was-db-migration'):
                docs = copy.deepcopy(self.docs['dev'])
                resource = next(d for d in docs if d['metadata']['name'] == name)
                resource['spec']['template']['spec']['containers'][0].setdefault('env', []).append({'name':field, 'value':bad})
                with self.assertRaisesRegex(ValueError, 'Dev email configuration'):
                    gate.validate(outputs, checks, docs, 'dev', NOW)

    def test_unverified_tls_is_not_reported_as_resolved(self):
        outputs, checks = fixtures()
        outputs["full_deploy_config"]["value"]["metrics_server_tls_verified"] = False
        with self.assertRaisesRegex(ValueError, "TLS remains unverified"):
            gate.validate(outputs, checks, self.docs["dev"], "dev", NOW)

    def test_every_required_manual_action_is_mandatory(self):
        for key in gate.REQUIRED_CHECKS:
            outputs, checks = fixtures()
            checks[key] = False
            with self.assertRaises(ValueError):
                gate.validate(outputs, checks, self.docs["dev"], "dev", NOW)

    def test_explicit_dev_slack_test_exception_keeps_rotation_pending(self):
        outputs, checks = fixtures()
        for key in gate.SLACK_ROTATION_CHECKS:
            checks[key] = False
        checks["slack_test_exception"] = dict(acknowledge_exposed_webhook=True,
            test_only_notifications=True, rotate_after_tests=True,
            expires_at=(NOW + timedelta(hours=8)).isoformat())
        gate.validate(outputs, checks, self.docs["dev"], "dev", NOW)
        self.assertTrue(all(checks[key] is False for key in gate.SLACK_ROTATION_CHECKS))
        # The exception changes only Slack timing, never the runtime gates.
        outputs["full_deploy_config"]["value"]["metrics_server_tls_verified"] = False
        with self.assertRaisesRegex(ValueError, "TLS remains unverified"):
            gate.validate(outputs, checks, self.docs["dev"], "dev", NOW)
        outputs["full_deploy_config"]["value"]["metrics_server_tls_verified"] = True
        checks["image_build_verified"] = False
        with self.assertRaisesRegex(ValueError, "image_build_verified"):
            gate.validate(outputs, checks, self.docs["dev"], "dev", NOW)
        checks["image_build_verified"] = True
        outputs["was_irsa_config"]["value"]["role_arn"] = ""
        with self.assertRaises(ValueError):
            gate.validate(outputs, checks, self.docs["dev"], "dev", NOW)

    def test_slack_test_exception_rejects_prod_missing_ack_and_invalid_deadlines(self):
        base = dict(acknowledge_exposed_webhook=True, test_only_notifications=True,
                    rotate_after_tests=True, expires_at=(NOW + timedelta(hours=1)).isoformat())
        mutations = [*[{key: False} for key in ("acknowledge_exposed_webhook", "test_only_notifications", "rotate_after_tests")],
                     *[{"expires_at": value} for value in ("", None, NOW.isoformat(),
                         (NOW - timedelta(seconds=1)).isoformat(), (NOW + timedelta(hours=9)).isoformat(),
                         NOW.replace(tzinfo=None).isoformat())]]
        for mutation in mutations:
            checks = {"slack_test_exception": dict(base, **mutation)}
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                gate.validate_slack_evidence(checks, "dev", NOW, NOW)
        with self.assertRaises(ValueError):
            gate.validate_slack_evidence({"slack_test_exception": base}, "prod", NOW, NOW)
        with self.assertRaises(ValueError):
            gate.validate_slack_evidence({"slack_test_exception": base}, "dev", NOW, NOW + timedelta(hours=2))
        for environment in ("dev", "prod"):
            gate.validate_slack_evidence(dict.fromkeys(gate.SLACK_ROTATION_CHECKS, True), environment, NOW, NOW)

    def test_stale_future_and_cross_environment_evidence_is_rejected(self):
        for value in ((NOW - timedelta(days=2)).isoformat(), (NOW + timedelta(minutes=1)).isoformat(), ""):
            outputs, checks = fixtures()
            checks["checked_at"] = value
            with self.assertRaises(ValueError):
                gate.validate(outputs, checks, self.docs["dev"], "dev", NOW)
        outputs, checks = fixtures("prod")
        with self.assertRaises(ValueError):
            gate.validate(outputs, checks, self.docs["dev"], "dev", NOW)

    def test_karpenter_missing_ami_or_confirmation_is_rejected(self):
        for field, value in (("ami_id", ""), ("verified", False)):
            outputs, checks = fixtures()
            outputs["full_deploy_config"]["value"]["karpenter"][field] = value
            with self.assertRaises(ValueError):
                gate.validate(outputs, checks, self.docs["dev"], "dev", NOW)

    def test_secret_scanner_detects_values_without_printing_them(self):
        webhook = "https://hooks.slack.com/services/" + "T" + "A" * 9 + "/B" + "B" * 9 + "/" + "c" * 24
        key = "AK" + "IA" + "0" * 16
        self.assertEqual({"SLACK_WEBHOOK", "AWS_ACCESS_ID"}, {kind for _, kind in scanner.findings(webhook + "\n" + key)})
        self.assertEqual([], list(scanner.findings('${var.slack_webhook_url} TEST_ONLY')))

    def test_runtime_and_build_contract(self):
        self.assertEqual("24.22.0", (ROOT / ".nvmrc").read_text().strip())
        for component in ("coupang_eats_backend_v2", "coupang_eats_frontend_v2"):
            folder = ROOT / "app" / component
            docker = (folder / "Dockerfile").read_text()
            self.assertNotIn("node:20", docker)
            self.assertIn("node:24.22.0-alpine", docker)
            package = json.loads((folder / "package.json").read_text())
            lock = json.loads((folder / "package-lock.json").read_text())
            self.assertEqual(package["engines"], lock["packages"][""]["engines"])
        backend = (ROOT / "app/coupang_eats_backend_v2/Dockerfile").read_text()
        package = json.loads((ROOT / "app/coupang_eats_backend_v2/package.json").read_text())
        self.assertNotIn("npm", package["dependencies"])
        self.assertNotIn("install", package["dependencies"])
        self.assertIn("node_modules/typeorm/cli.js", package["scripts"]["migration:run"])
        self.assertIn("npm prune --omit=dev", backend)
        self.assertIn("USER node", backend)
        self.assertIn('-name "*.map"', backend)
        self.assertNotIn("COPY . .", backend.split("AS runner")[1])

    def test_runtime_bindings_are_required_and_prod_incomplete_is_blocked(self):
        outputs, checks = fixtures()
        del outputs["runtime_bindings"]
        with self.assertRaises(ValueError):
            gate.validate(outputs, checks, self.docs["dev"], "dev", NOW)
        outputs, checks = fixtures("prod")
        outputs["runtime_bindings"]["value"]["infrastructure_complete"] = False
        with self.assertRaisesRegex(ValueError, "infrastructure is incomplete"):
            gate.validate(outputs, checks, self.docs["prod"], "prod", NOW)

    def test_wrong_secret_provider_role_sg_cidr_and_image_are_blocked(self):
        mutations = [
            ("ServiceAccount", "eso-service-account", lambda r: r["metadata"]["annotations"].update({"eks.amazonaws.com/role-arn": ""})),
            ("ExternalSecret", "was-db-external-secret", lambda r: r["spec"]["data"][0]["remoteRef"].update(key="foreign-secret")),
            ("SecretStore", "aws-secrets-manager-store", lambda r: r["spec"]["provider"]["aws"].update(role="foreign-role")),
            ("Ingress", "main-ingress", lambda r: r["metadata"]["annotations"].update({"alb.ingress.kubernetes.io/security-groups": "other-sg"})),
            ("NetworkPolicy", "was-dependencies", lambda r: r["spec"]["egress"][0]["to"][0]["ipBlock"].update(cidr="0.0.0.0/0")),
            ("Deployment", "was-deployment", lambda r: r["spec"]["template"]["spec"]["containers"][0].update(image="was:latest")),
            ("Job", "was-db-migration", lambda r: r["spec"]["template"]["spec"]["containers"][0].update(env=[{"name":"DB_HOST", "value":"direct-aurora"}])),
        ]
        for kind, name, mutate in mutations:
            outputs, checks = fixtures()
            docs = copy.deepcopy(self.docs["dev"])
            mutate(next(r for r in docs if r["kind"] == kind and r["metadata"]["name"] == name))
            with self.subTest(kind=kind, name=name), self.assertRaises(ValueError):
                gate.validate(outputs, checks, docs, "dev", NOW)

    def test_waf_none_cannot_bypass_enabled_terraform_acl(self):
        outputs, checks = fixtures()
        outputs["runtime_bindings"]["value"]["waf"] = {"enabled": True, "web_acl_arn": "arn:aws:wafv2:ap-northeast-2:123456789012:regional/webacl/food-delivery-dev-waf/11111111-1111-1111-1111-111111111111"}
        with self.assertRaisesRegex(ValueError, "WAF Terraform state"):
            gate.validate(outputs, checks, self.docs["dev"], "dev", NOW)

    def test_stale_redis_auth_secret_is_rejected(self):
        outputs, checks = fixtures()
        docs = copy.deepcopy(self.docs["dev"])
        external = next(r for r in docs if r["kind"] == "ExternalSecret")
        next(r for r in external["spec"]["data"] if r["secretKey"] == "REDIS_HOST")["remoteRef"]["key"] = outputs["runtime_bindings"]["value"]["eso"]["authentication_secret_name"]
        with self.assertRaises(ValueError):
            gate.validate(outputs, checks, docs, "dev", NOW)

    def test_custom_vpc_prefix_and_enabled_waf_roundtrip(self):
        outputs, checks = fixtures()
        value = outputs["runtime_bindings"]["value"]
        value.update(vpc_cidr="10.42.0.0/16", public_subnet_cidrs=["10.42.0.0/24"], private_subnet_cidrs=["10.42.10.0/24"])
        value["eso"].update(authentication_secret_name="owner-rds-aurora-credentials", connection_secret_name="owner-rds-aurora-credentials-connection")
        value["waf"] = {"enabled": True, "web_acl_arn": "arn:aws:wafv2:ap-northeast-2:123456789012:regional/webacl/food-delivery-dev-waf/11111111-1111-1111-1111-111111111111"}
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory) / "k8s"
            shutil.copytree(self.repo / "k8s", folder)
            overlay = folder / "overlays/dev"
            for name, content in module("render-runtime-bindings").patches(value, "dev").items():
                (overlay / name).write_text(content)
            (overlay / "waf-patch.yaml").write_text(module("render-waf-ingress").render(dict(environment="dev", **value["waf"])))
            bind_certificate(overlay)
            yaml = subprocess.check_output([os.environ.get("KUSTOMIZE_BIN", "kustomize"), "build", str(overlay)], text=True)
            docs = json.loads(subprocess.check_output(["ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.load_stream(STDIN.read).compact)"], input=yaml, text=True))
            gate.validate(outputs, checks, docs, "dev", NOW)

    def test_runtime_input_rejects_foreign_identity_wildcards_and_direct_aurora(self):
        values = []
        for key, bad in (("account_id", "111111111111"), ("region", "us-east-1"), ("alb_security_group_id", "alb-sg"),
                         ("db_proxy_endpoint", "writer.cluster-example.ap-northeast-2.rds.amazonaws.com"), ("vpc_cidr", "0.0.0.0/0")):
            value = fixtures()[0]["runtime_bindings"]["value"]
            value[key] = bad
            values.append(value)
        value = fixtures()[0]["runtime_bindings"]["value"]
        value["eso"]["authentication_secret_name"] = "*"
        values.append(value)
        for value in values:
            with self.assertRaises(ValueError):
                module("render-runtime-bindings").patches(value, "dev")

    def test_source_gate_accepts_docs_commits_and_rejects_old_or_dirty_build_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            (repo / "app").mkdir()
            source = repo / "app/runtime.txt"
            source.write_text("tested source")
            def git(*args):
                return subprocess.check_output(["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "-C", str(repo), *args], text=True, stderr=subprocess.DEVNULL).strip()
            git("init", "-q")
            git("add", "app")
            git("-c", "user.name=Audit Fixture", "-c", "user.email=audit@example.test", "commit", "-qm", "source")
            sha = git("rev-parse", "HEAD")
            docs = copy.deepcopy(self.docs["dev"])
            was = next(r for r in docs if r["kind"] == "Deployment" and r["metadata"]["name"] == "was-deployment")
            was["spec"]["template"]["spec"]["containers"][0]["image"] = "was:" + sha
            gate.validate_image_source(docs, "dev", repo)
            (repo / "README.md").write_text("documentation")
            git("add", "README.md")
            git("-c", "user.name=Audit Fixture", "-c", "user.email=audit@example.test", "commit", "-qm", "docs")
            gate.validate_image_source(docs, "dev", repo)
            (repo / "app/untracked.ts").write_text("new build input")
            with self.assertRaises(ValueError):
                gate.validate_image_source(docs, "dev", repo)
            (repo / "app/untracked.ts").unlink()
            source.write_text("new source")
            with self.assertRaises(ValueError):
                gate.validate_image_source(docs, "dev", repo)
            git("add", "app")
            git("-c", "user.name=Audit Fixture", "-c", "user.email=audit@example.test", "commit", "-qm", "next source")
            with self.assertRaises(ValueError):
                gate.validate_image_source(docs, "dev", repo)

    def test_retired_apply_entrypoints_never_call_external_tools(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            calls = folder / "calls"
            for name in ("aws", "terraform", "kubectl", "curl"):
                path = folder / name
                path.write_text('#!/bin/sh\nprintf called >> "$AUDIT_EXTERNAL_CALLS"\nexit 99\n')
                path.chmod(0o700)
            env = dict(os.environ, PATH=str(folder)+":"+os.environ["PATH"], AUDIT_EXTERNAL_CALLS=str(calls), CONFIRM="APPLY")
            paths = [ROOT / "scripts" / name for name in ("full-security-cycle.sh", "security-runbook.sh", "run-security-cycle.command")]
            paths.append(ROOT / "setup_secrets_and_templates.sh")
            for path in paths:
                result = subprocess.run(["bash", str(path)], env=env, capture_output=True, text=True)
                self.assertNotEqual(0, result.returncode)
                self.assertIn("disabled", result.stderr)
            self.assertFalse(calls.exists())

    def test_rendered_placeholder_roles_are_not_deploy_ready(self):
        docs = copy.deepcopy(self.docs["dev"])
        for resource in docs:
            if resource["kind"] == "ServiceAccount" and resource["metadata"]["name"] in ("food-delivery-was", "adot-collector"):
                resource["metadata"]["annotations"]["eks.amazonaws.com/role-arn"] = ""
        outputs, checks = fixtures()
        with self.assertRaisesRegex(ValueError, "Rendered ServiceAccount role"):
            gate.validate(outputs, checks, docs, "dev", NOW)

    def test_cli_malformed_input_is_nonzero_and_does_not_echo_content(self):
        with tempfile.TemporaryDirectory() as directory:
            bad, checks = Path(directory) / "outputs.json", Path(directory) / "checks.json"
            bad.write_text('{INVALID_PRIVATE_SENTINEL')
            checks.write_text('{}')
            result = subprocess.run(["python3", str(ROOT / "scripts/pre-full-deploy.py"), "--environment", "dev", "--outputs-file", str(bad), "--checks-file", str(checks)], capture_output=True, text=True)
            self.assertNotEqual(0, result.returncode)
            self.assertNotIn("PRIVATE_SENTINEL", result.stdout + result.stderr)
            self.assertIn("PREFLIGHT BLOCKED", result.stderr)


if __name__ == "__main__":
    unittest.main()
