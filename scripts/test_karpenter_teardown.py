"""Mock-only Karpenter teardown boundary/order tests; never calls live tools."""
import io
import json
import tempfile
import unittest
from pathlib import Path
from contextlib import redirect_stdout

from test_safe_teardown import FakeRunner, resource, teardown, TAGS, VPC, LB


class KarpenterRunner(FakeRunner):
    def __init__(self):
        super().__init__()
        self.candidates = [LB]
        self.state["values"]["root_module"]["child_modules"][0]["resources"].append(
            resource("module.eks.helm_release.karpenter[0]", "helm_release", name="karpenter", namespace="kube-system"))
        self.pool = {
            "apiVersion": "karpenter.sh/v1", "kind": "NodePool",
            "metadata": {"name": teardown.KARPENTER_POOL, "labels": {
                "app.kubernetes.io/part-of": "food-delivery", "food-delivery/environment": "dev"}},
            "spec": {"template": {"spec": {"nodeClassRef": {
                "group": "karpenter.k8s.aws", "kind": "EC2NodeClass", "name": teardown.KARPENTER_POOL}}}}}
        self.instance_tags = {**TAGS, "kubernetes.io/cluster/cluster": "owned",
                              "karpenter.sh/nodepool": teardown.KARPENTER_POOL, "food-delivery/cluster": "cluster"}
        self.deleted_pool = False
        self.stuck = False
        self.ec2_owner = teardown.ACCOUNT
        self.missing_crds = set()
        self.nodeclass_present = True
        self.nodeclass_stuck = False

    def aws(self, service, operation, *args):
        if (service, operation) == ("ec2", "describe-instances"):
            self.calls.append((service, operation, args))
            instances = [] if self.deleted_pool and not self.stuck else [{
                "InstanceId": "i-0123456789abcdef0", "VpcId": VPC,
                "Tags": [{"Key": k, "Value": v} for k, v in self.instance_tags.items()]}]
            return {"Reservations": [{"OwnerId": self.ec2_owner, "Instances": instances}]}
        return super().aws(service, operation, *args)

    def kube(self, context, *args, structured=False):
        if args[:2] == ("get", "nodepool.karpenter.sh"):
            self.calls.append(("kubectl", args[0], args[1:]))
            return json.dumps(self.pool) if self.pool and not self.deleted_pool else ""
        if args[:2] == ("delete", "nodepool.karpenter.sh"):
            self.calls.append(("kubectl", args[0], args[1:]))
            self.deleted_pool = True
            return "deleted"
        if args[:2] == ("get", "nodeclaims.karpenter.sh"):
            self.calls.append(("kubectl", args[0], args[1:]))
            result = {"items": [{"metadata": {"name": "claim"}}] if self.stuck else []}
            return result if structured else json.dumps(result)
        if args[:2] == ("get", "crd"):
            self.calls.append(("kubectl", args[0], args[1:]))
            return "" if args[2] in self.missing_crds else f"customresourcedefinition.apiextensions.k8s.io/{args[2]}"
        if args[:2] == ("delete", "ec2nodeclass.karpenter.k8s.aws"):
            self.calls.append(("kubectl", args[0], args[1:]))
            self.nodeclass_present = self.nodeclass_stuck
            return "deleted"
        if args[:2] == ("get", "ec2nodeclass.karpenter.k8s.aws"):
            self.calls.append(("kubectl", args[0], args[1:]))
            return f"ec2nodeclass.karpenter.k8s.aws/{args[2]}" if self.nodeclass_present else ""
        return super().kube(context, *args, structured=structured)


class KarpenterTeardownTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        metadata = self.root / "infra/environments/dev/.terraform/terraform.tfstate"
        metadata.parent.mkdir(parents=True)
        metadata.write_text(json.dumps({"backend": {"type": "s3", "config": {
            "bucket": "example-terraform-state-bucket", "key": "terraform/dev/terraform.tfstate",
            "region": teardown.REGION, "use_lockfile": True}}}))
        self.runner = KarpenterRunner()

    def run_teardown(self, execute=False):
        with redirect_stdout(io.StringIO()):
            return teardown.run(self.runner, {"CONFIRM": "DESTROY", "WAIT_SECONDS": "0"},
                                execute=execute, root=self.root, sleep=lambda _: None)

    def test_dry_run_lists_exact_instances_without_deleting(self):
        view = self.run_teardown()
        self.assertEqual(["i-0123456789abcdef0"], view["karpenter_instances"])
        self.assertFalse(self.runner.deleted_pool)
        self.assertFalse(any(op in {"apply", "delete", "annotate", "terminate-instances"} for _, op, _ in self.runner.calls))
        filters = next(args for service, op, args in self.runner.calls if service == "ec2" and op == "describe-instances")
        self.assertIn(f"Name=vpc-id,Values={VPC}", filters)
        self.assertIn("Name=tag:kubernetes.io/cluster/cluster,Values=owned", filters)
        self.assertIn("Name=tag:karpenter.sh/nodepool,Values=food-delivery-app", filters)

    def test_controller_cleans_nodes_before_terraform_destroy(self):
        self.run_teardown(True)
        calls = self.runner.calls
        application_delete = next(i for i, (s, op, a) in enumerate(calls) if s == "kubectl" and op == "delete" and a[0] == "application")
        pool_delete = next(i for i, (s, op, a) in enumerate(calls) if s == "kubectl" and op == "delete" and a[0] == "nodepool.karpenter.sh")
        claim_check = next(i for i, (s, op, a) in enumerate(calls) if i > pool_delete and s == "kubectl" and a[0] == "nodeclaims.karpenter.sh")
        apply = next(i for i, (s, op, _) in enumerate(calls) if s == "terraform" and op == "apply")
        self.assertLess(application_delete, pool_delete)
        self.assertLess(pool_delete, claim_check)
        self.assertLess(claim_check, apply)
        self.assertFalse(any(op in {"terminate-instances", "delete-security-group"} for _, op, _ in calls))

    def test_foreign_instance_tags_abort_before_any_mutation(self):
        for key, value in {"Project": "other", "Environment": "prod", "ManagedBy": "manual",
                           "food-delivery/cluster": "foreign", "karpenter.sh/nodepool": "foreign"}.items():
            with self.subTest(key=key):
                self.runner = KarpenterRunner()
                self.runner.instance_tags[key] = value
                with self.assertRaises(teardown.UnsafeTeardown):
                    self.run_teardown(True)
                self.assertFalse(any(op in {"apply", "delete", "annotate"} for _, op, _ in self.runner.calls))

    def test_foreign_pool_reference_and_ec2_owner_abort(self):
        self.runner.pool["spec"]["template"]["spec"]["nodeClassRef"]["name"] = "foreign"
        with self.assertRaises(teardown.UnsafeTeardown):
            self.run_teardown(True)
        self.assertFalse(self.runner.deleted_pool)
        self.runner = KarpenterRunner()
        self.runner.ec2_owner = "999999999999"
        with self.assertRaises(teardown.UnsafeTeardown):
            self.run_teardown(True)

    def test_stuck_nodeclaim_prevents_controller_iam_vpc_destroy(self):
        self.runner.stuck = True
        with self.assertRaisesRegex(teardown.UnsafeTeardown, "Karpenter nodes still exist"):
            self.run_teardown(True)
        self.assertTrue(self.runner.deleted_pool)
        self.assertFalse(any(s == "terraform" and op == "apply" for s, op, _ in self.runner.calls))

    def test_ec2nodeclass_finalized_before_terraform_destroy(self):
        self.run_teardown(True)
        calls = self.runner.calls
        claim_check = max(i for i, (s, op, a) in enumerate(calls) if s == "kubectl" and op == "get" and a[0] == "nodeclaims.karpenter.sh")
        class_delete = next(i for i, (s, op, a) in enumerate(calls) if s == "kubectl" and op == "delete" and a[0] == "ec2nodeclass.karpenter.k8s.aws")
        class_gone = max(i for i, (s, op, a) in enumerate(calls) if s == "kubectl" and op == "get" and a[0] == "ec2nodeclass.karpenter.k8s.aws")
        apply = next(i for i, (s, op, _) in enumerate(calls) if s == "terraform" and op == "apply")
        self.assertLess(claim_check, class_delete)
        self.assertLess(class_delete, class_gone)
        self.assertLess(class_gone, apply)

    def test_stuck_ec2nodeclass_finalizer_prevents_destroy(self):
        self.runner.nodeclass_stuck = True
        with self.assertRaisesRegex(teardown.UnsafeTeardown, "EC2NodeClass finalizer did not finish"):
            self.run_teardown(True)
        self.assertFalse(any(s == "terraform" and op == "apply" for s, op, _ in self.runner.calls))

    def test_rerun_after_partial_destroy_treats_missing_crds_as_absent(self):
        self.runner.deleted_pool = True
        self.runner.missing_crds = set(teardown.OPTIONAL_CRDS.values())
        self.run_teardown(True)
        gets = [a[0] for s, op, a in self.runner.calls if s == "kubectl" and op == "get"]
        for kind in teardown.OPTIONAL_CRDS:
            self.assertNotIn(kind, gets)
        self.assertTrue(any(s == "terraform" and op == "apply" for s, op, _ in self.runner.calls))

    def test_missing_nodepool_does_not_force_delete_runtime_nodes(self):
        self.runner.pool = None
        with self.assertRaises(teardown.UnsafeTeardown):
            self.run_teardown(True)
        self.assertFalse(any(op == "terminate-instances" for _, op, _ in self.runner.calls))


if __name__ == "__main__":
    unittest.main()
