"""Offline integration tests. Kustomize builds temporary copies, no AWS calls."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("render_waf", ROOT / "scripts/render-waf-ingress.py")
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)
ARN = "arn:aws:wafv2:ap-northeast-2:123456789012:regional/webacl/food-delivery-dev-waf/11111111-1111-1111-1111-111111111111"


class WafIngressTest(unittest.TestCase):
    def config(self, enabled=True, arn=ARN):
        return {"environment": "dev", "enabled": enabled, "web_acl_arn": arn}

    def test_enabled_and_disabled_render_only_waf_annotation(self):
        enabled = json.loads(subprocess.check_output(
            ["ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.load(STDIN.read))"],
            input=renderer.render(self.config()).encode()))
        self.assertEqual(enabled["metadata"]["annotations"], {"alb.ingress.kubernetes.io/wafv2-acl-arn": ARN})
        self.assertNotIn("spec", enabled)
        self.assertIn('"none"', renderer.render(self.config(False, None)))

    def test_wrong_region_scope_environment_and_inconsistent_flags_rejected(self):
        for config in [None, {}, self.config(True, None), self.config(False, ARN),
                       self.config(True, ARN.replace("ap-northeast-2", "us-east-1")),
                       self.config(True, ARN.replace("regional/", "global/")),
                       self.config(True, ARN.replace("123456789012", "111111111111")),
                       self.config(True, ARN.replace("-dev-waf/", "-prod-waf/")),
                       {**self.config(), "environment": "prod"},
                       {**self.config(), "enabled": 1}]:
            with self.subTest(config=config), self.assertRaises(ValueError):
                renderer.render(config)

    def test_bad_input_does_not_overwrite_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "patch.yaml"
            path.write_text("preserve this")
            result = subprocess.run(["python3", str(ROOT / "scripts/render-waf-ingress.py"), "--output", str(path)],
                                    input="{}", text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(path.read_text(), "preserve this")

    def test_real_dev_render_and_prod_isolation_without_routing_or_image_change(self):
        kustomize = os.environ.get("KUSTOMIZE_BIN", "kustomize")
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            shutil.copytree(ROOT / "k8s", repo / "k8s")
            def build(env):
                return subprocess.check_output([kustomize, "build", str(repo / "k8s/overlays" / env)], text=True)
            before = build("dev")
            prod_before = build("prod")
            patch = repo / "k8s/overlays/dev/waf-patch.yaml"
            patch.write_text(renderer.render(self.config()))
            after = build("dev")
            self.assertIn(ARN, after)
            # The only rendered change is the annotation's value.
            self.assertEqual(before.replace('wafv2-acl-arn: none', 'wafv2-acl-arn: '+ARN), after)
            self.assertEqual(prod_before, build("prod"))
            self.assertNotIn(ARN, prod_before)
            patch.write_text(renderer.render(self.config(False, None)))
            self.assertEqual(before, build("dev"))

    def test_controller_is_only_association_owner(self):
        module = (ROOT / "infra/modules/waf/main.tf").read_text()
        self.assertNotIn('resource "aws_wafv2_web_acl_association"', module)
        self.assertNotIn('"alb_arn"', (ROOT / "infra/modules/waf/variables.tf").read_text())
        self.assertNotIn("local.ingress_alb_arn", (ROOT / "infra/environments/dev/main.tf").read_text().split('module "waf"')[1])
        script = (ROOT / "scripts/render-waf-ingress.py").read_text()
        self.assertNotIn("subprocess", script)


if __name__ == "__main__":
    unittest.main()
