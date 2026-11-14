"""Regression checks for private inputs accidentally committed as fixtures."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("public_identifiers", ROOT / "scripts/ci/check-public-identifiers.py")
scanner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scanner)


class PublicIdentifierTests(unittest.TestCase):
    def test_private_bucket_in_a_test_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            path = root / "test-setup.ts"
            variable = "AWS_S3_" + "BUCKET_NAME"
            path.write_text(f"process.env.{variable}='department-production-uploads';\n")
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)
            self.assertIn(("test-setup.ts", 1, "literal-upload-bucket"), scanner.scan(root, []))

    def test_example_bucket_and_secret_reference_are_allowed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / "fixture.ts").write_text("process.env.AWS_S3_BUCKET_NAME='example-upload-bucket';\n")
            (root / "reference.yaml").write_text("secretKeyRef:\n  name: runtime-secret\n  key: DB_PASSWORD\n")
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)
            self.assertEqual(scanner.scan(root, []), [])

    def test_private_file_is_rejected_even_without_a_key_pattern(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / ".env.local").write_text("REGION=local\n")
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)
            self.assertIn((".env.local", 1, "tracked-sensitive-file"), scanner.scan(root, []))

    def test_private_paths_and_public_examples(self):
        for rel in ["state/terraform.tfstate.backup", "config/prod-target.json", "infra/backend.hcl", "prod.tfvars.json", "credentials", "kubeconfig.dev"]:
            with self.subTest(rel=rel):
                self.assertTrue(scanner.sensitive_filename(rel))
        for rel in ["dotenv/.env.example", "infra/backend.hcl.example", "infra/terraform.tfvars.example", "config/prod-target.example.json"]:
            with self.subTest(rel=rel):
                self.assertFalse(scanner.sensitive_filename(rel))


if __name__ == "__main__":
    unittest.main()
