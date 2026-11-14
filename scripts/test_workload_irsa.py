"""Offline output-to-GitOps tests. Never calls AWS, Terraform, or kubectl."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("irsa_renderer", ROOT / "scripts/render-workload-irsa.py")
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)


def fixture(environment="dev"):
    return dict(environment=environment, namespace="app" if environment == "dev" else "app-prod",
                service_account="food-delivery-was", account_id="123456789012", region="ap-northeast-2",
                role_arn=f"arn:aws:iam::123456789012:role/cluster-{environment}-was",
                s3_bucket_name=f"food-delivery-{environment}-assets-test", ses_from_address="sender@example.com")


class WorkloadIrsaTest(unittest.TestCase):
    def test_output_render_matches_both_environment_trust_boundaries(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copytree(ROOT / "k8s", root / "k8s")
            for environment in ("dev", "prod"):
                value = fixture(environment)
                patch = root / "k8s/overlays" / environment / "was-irsa-patch.yaml"
                patch.write_text(renderer.render(value, environment))
                output = subprocess.check_output([os.environ.get("KUSTOMIZE_BIN", "kustomize"), "build",
                                                  str(patch.parent)], text=True)
                docs = json.loads(subprocess.check_output(
                    ["ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.load_stream(STDIN.read).compact)"],
                    input=output, text=True))
                sa = next(r for r in docs if r["kind"] == "ServiceAccount" and r["metadata"]["name"] == "food-delivery-was")
                self.assertEqual(value["namespace"], sa["metadata"]["namespace"])
                self.assertEqual(value["role_arn"], sa["metadata"]["annotations"]["eks.amazonaws.com/role-arn"])
                self.assertEqual("true", sa["metadata"]["annotations"]["eks.amazonaws.com/sts-regional-endpoints"])
                self.assertFalse(sa["automountServiceAccountToken"])
                config = next(r for r in docs if r["kind"] == "ConfigMap" and r["metadata"]["name"] == "was-config")["data"]
                self.assertEqual(value["s3_bucket_name"], config["AWS_S3_BUCKET_NAME"])
                self.assertEqual("" if environment == "dev" else value["ses_from_address"], config["AWS_SES_SENDER_EMAIL"])
                self.assertEqual("true" if environment == "dev" else "false", config["SKIP_EMAIL_NOTIFICATION"])
                for item in docs:
                    if item["kind"] not in {"Deployment", "Job"}:
                        continue
                    pod = item["spec"]["template"]["spec"]
                    if item["kind"] == "Deployment":
                        self.assertFalse(pod["automountServiceAccountToken"])
                    if item["metadata"]["name"] == "was-deployment":
                        self.assertEqual("food-delivery-was", pod["serviceAccountName"])
                        env = {v["name"]: v.get("value") for v in pod["containers"][0]["env"]}
                        self.assertEqual("true", env["AWS_EC2_METADATA_DISABLED"])
                        self.assertNotIn("AWS_ROLE_ARN", env)
                        self.assertNotIn("AWS_WEB_IDENTITY_TOKEN_FILE", env)
                    else:
                        self.assertNotEqual("food-delivery-was", pod.get("serviceAccountName"))

    def test_wrong_environment_identity_and_injection_are_rejected(self):
        for key, value in {"environment": "prod", "namespace": "default", "account_id": "111111111111",
                           "region": "us-east-1", "service_account": "default",
                           "role_arn": "arn:aws:iam::123456789012:role/cluster-prod-was",
                           "s3_bucket_name": "bucket/*", "ses_from_address": "sender@example.com\ncredential: secret"}.items():
            with self.subTest(key=key):
                item = fixture()
                item[key] = value
                with self.assertRaises(ValueError):
                    renderer.render(item, "dev")

    def test_missing_configuration_keeps_features_disabled(self):
        item = fixture()
        item.update(s3_bucket_name="", ses_from_address="")
        result = renderer.render(item, "dev")
        self.assertIn('SKIP_EMAIL_NOTIFICATION: "true"', result)
        self.assertIn('AWS_S3_BUCKET_NAME: ""', result)

    def test_dev_stays_disabled_even_with_configured_sender(self):
        value = fixture()
        result = renderer.render(value, "dev")
        self.assertIn('SKIP_EMAIL_NOTIFICATION: "true"', result)
        self.assertIn('AWS_SES_SENDER_EMAIL: ""', result)
        self.assertNotIn(value['ses_from_address'], result)

    def test_invalid_cli_input_preserves_existing_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "patch.yaml"
            path.write_text("preserve this")
            result = subprocess.run(["python3", str(ROOT / "scripts/render-workload-irsa.py"),
                                     "--environment", "dev", "--output", str(path)],
                                    input='{"role_arn":"bad"}', text=True, capture_output=True)
            self.assertNotEqual(0, result.returncode)
            self.assertEqual("preserve this", path.read_text())

    def test_node_roles_and_runtime_credentials_remain_separate(self):
        mng = (ROOT / "infra/modules/eks/iam.tf").read_text()
        self.assertNotIn("AmazonS3ReadOnlyAccess", mng)
        self.assertNotIn("ses:Send", mng)
        self.assertNotIn('"node_ses_send"', mng)
        karpenter = (ROOT / "infra/modules/eks/karpenter.tf").read_text()
        self.assertNotIn("ses:", karpenter)
        self.assertNotIn("s3:", karpenter)
        self.assertIn('"AmazonEKSWorkerNodePolicy", "AmazonEC2ContainerRegistryPullOnly"', karpenter)
        for path in (ROOT / "app/coupang_eats_backend_v2/src").rglob("*.ts"):
            if path.name.endswith(".spec.ts"):
                continue
            text = path.read_text()
            for pattern in ("accessKeyId:", "secretAccessKey:", "AWS_ACCESS_KEY_ID=", "AWS_SECRET_ACCESS_KEY="):
                self.assertNotIn(pattern, text, str(path))
        for path in (ROOT / "k8s").rglob("*.yaml"):
            self.assertNotIn("AWS_ACCESS_KEY_ID", path.read_text())
            self.assertNotIn("AWS_SECRET_ACCESS_KEY", path.read_text())


if __name__ == "__main__":
    unittest.main()
