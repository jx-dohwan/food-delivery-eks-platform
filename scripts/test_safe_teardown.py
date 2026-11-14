"""Pure mocked subprocess runner: no AWS, kubectl, Terraform mutations or sleep."""
import importlib.util
import copy
import io
import json
from pathlib import Path
import tempfile
import unittest
import os

# Synthetic identity for tests; the real values come from a git-ignored private target.
os.environ.setdefault("FOOD_DELIVERY_ACCOUNT_ID", "123456789012")
os.environ.setdefault("FOOD_DELIVERY_STATE_BUCKET", "example-terraform-state-bucket")
from contextlib import redirect_stdout
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("safe_teardown", Path(__file__).with_name("safe_teardown.py"))
teardown = importlib.util.module_from_spec(spec)
spec.loader.exec_module(teardown)

VPC = "vpc-0123456789abcdef0"
CLUSTER = "arn:aws:eks:ap-northeast-2:123456789012:cluster/cluster"
LB = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:loadbalancer/app/own/1234"
FOREIGN_LB = LB.replace("/own/", "/foreign/")
ACL = "arn:aws:wafv2:ap-northeast-2:123456789012:regional/webacl/food-delivery-dev-waf/uuid"
ECR = "arn:aws:ecr:ap-northeast-2:123456789012:repository/was"
TAGS = {"Project": "food-delivery", "Environment": "dev", "ManagedBy": "terraform"}
LB_TAGS = {"elbv2.k8s.aws/cluster": "cluster", "ingress.k8s.aws/stack": "app/main-ingress",
           "ingress.k8s.aws/resource": "LoadBalancer"}


def resource(address, kind, **values):
    return {"address": address, "type": kind, "mode": "managed", "values": values}


def state_document():
    return {"values": {"root_module": {"child_modules": [{"address": "module.mock", "resources": [
        resource("module.network.aws_vpc.this", "aws_vpc", id=VPC, arn=f"arn:aws:ec2:ap-northeast-2:123456789012:vpc/{VPC}"),
        resource("module.eks.aws_eks_cluster.this", "aws_eks_cluster", id="cluster", name="cluster", arn=CLUSTER, tags=TAGS),
        resource("module.waf.aws_wafv2_web_acl.this[0]", "aws_wafv2_web_acl", id="uuid", arn=ACL, tags=TAGS),
        resource('module.ecr.aws_ecr_repository.this["was"]', "aws_ecr_repository", id="was", name="was", arn=ECR, tags=TAGS)
    ]}]}}}


class FakeRunner:
    def __init__(self):
        self.calls = []
        self.state = state_document()
        self.account = teardown.ACCOUNT
        self.workspace = "default"
        self.lb_tags = {LB: LB_TAGS, FOREIGN_LB: {**LB_TAGS, "elbv2.k8s.aws/cluster": "other"}}
        self.candidates = [LB, FOREIGN_LB]
        self.acl = ACL
        self.acl_tags = TAGS
        self.ecr_tags = TAGS
        self.cluster = {"name": "cluster", "arn": CLUSTER, "endpoint": "https://own.example",
                        "certificateAuthority": {"data": "OWN-CA"}, "tags": TAGS,
                        "resourcesVpcConfig": {"vpcId": VPC}}
        self.context_endpoint = "https://own.example"
        self.kube_deleted = False
        self.missing_after_reclaim = True
        self.argo_repo = "https://github.com/jx-dohwan/food-delivery-eks-platform.git"
        self.after_apply = False
        self.cascade_ingress_deleted = False
        self.ingress_hostname = None
        self.ingress_waf = None

    def aws(self, service, operation, *args):
        self.calls.append((service, operation, args))
        if (service, operation) == ("sts", "get-caller-identity"):
            return {"Account": self.account, "Arn": f"arn:aws:iam::{self.account}:user/operator"}
        if (service, operation) == ("ec2", "describe-vpcs"):
            return {"Vpcs": [{"VpcId": VPC, "OwnerId": self.account, "IsDefault": False}]}
        if (service, operation) == ("eks", "describe-cluster"):
            return {"cluster": self.cluster}
        if service == "resourcegroupstaggingapi":
            return {"ResourceTagMappingList": [{"ResourceARN": arn} for arn in self.candidates]}
        if operation == "describe-load-balancers":
            if self.kube_deleted and self.missing_after_reclaim:
                raise teardown.CommandFailed("aws", "LoadBalancerNotFound")
            return {"LoadBalancers": [{"LoadBalancerArn": args[1], "VpcId": VPC, "Type": "application"}]}
        if operation == "describe-tags":
            return {"TagDescriptions": [{"Tags": [{"Key": k, "Value": v} for k, v in self.lb_tags[args[1]].items()]}]}
        if operation == "get-web-acl-for-resource":
            return {"WebACL": {"ARN": self.acl}} if self.acl else {}
        if operation == "list-tags-for-resource":
            if service == "wafv2":
                return {"TagInfoForResource": {"TagList": [{"Key": k, "Value": v} for k, v in self.acl_tags.items()]}}
            return {"tags": [{"Key": k, "Value": v} for k, v in self.ecr_tags.items()]}
        if operation == "describe-repositories":
            return {"repositories": [{"repositoryArn": ECR}]}
        if operation == "disassociate-web-acl":
            self.acl = None
            return {}
        raise AssertionError(f"Unexpected AWS operation: {service} {operation}")

    def tf(self, *args, structured=False):
        self.calls.append(("terraform", args[0], args[1:]))
        if args[:2] == ("workspace", "show"):
            return self.workspace
        if args[0] == "plan":
            return "mock destroy plan"
        if args[0] == "apply":
            self.after_apply = True
            return "mock apply"
        if args[:2] == ("show", "-json"):
            if len(args) == 3:
                return {"resource_changes": [{"address": address, "mode": "managed", "type": res["type"],
                        "change": {"actions": ["delete"], "before": res["values"]}}
                        for address, res in teardown.resources(self.state).items()]}
            return {} if self.after_apply else self.state
        raise AssertionError(f"Unexpected Terraform operation: {args[0]}")

    def kube(self, context, *args, structured=False):
        self.calls.append(("kubectl", args[0], args[1:]))
        if args[0] == "config":
            return {"clusters": [{"cluster": {"server": self.context_endpoint, "certificate-authority-data": "OWN-CA"}}]}
        if args[0] == "get":
            if args[1] == "crd":
                return f"customresourcedefinition.apiextensions.k8s.io/{args[2]}"
            if args[1] == "application":
                return json.dumps({"spec": {"source": {"repoURL": self.argo_repo, "targetRevision": "main", "path": "k8s/overlays/dev"},
                    "destination": {"namespace": "app", "server": "https://kubernetes.default.svc"}}})
            if self.cascade_ingress_deleted and self.kube_deleted:
                return ""
            obj = {"metadata": {"annotations": {}}, "spec": {"ingressClassName": "alb"}}
            if self.ingress_hostname:
                obj["status"] = {"loadBalancer": {"ingress": [{"hostname": self.ingress_hostname}]}}
            if self.ingress_waf:
                obj["metadata"]["annotations"]["alb.ingress.kubernetes.io/wafv2-acl-arn"] = self.ingress_waf
            return json.dumps(obj)
        if args[0] in {"delete", "annotate"}:
            self.kube_deleted = True
            return "mock mutation"
        raise AssertionError("Unexpected kubectl operation")


class TeardownTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        metadata = self.root / "infra/environments/dev/.terraform/terraform.tfstate"
        metadata.parent.mkdir(parents=True)
        metadata.write_text(json.dumps({"backend": {"type": "s3", "config": {
            "bucket": "example-terraform-state-bucket", "key": "terraform/dev/terraform.tfstate", "region": teardown.REGION,
            "use_lockfile": True}}}))
        self.runner = FakeRunner()

    def run_teardown(self, execute=False, **environ):
        with redirect_stdout(io.StringIO()):
            return teardown.run(self.runner, environ, execute=execute, root=self.root, sleep=lambda _: None)

    def assert_no_mutation(self):
        self.assertFalse(any(op in {"apply", "destroy", "delete", "annotate", "disassociate-web-acl",
                                   "delete-load-balancer", "delete-repository", "delete-network-interface"}
                             for _, op, _ in self.runner.calls))

    def test_dry_run_owned_alb_selected_foreign_skipped_no_mutations(self):
        view = self.run_teardown()
        self.assertEqual([lb["arn"] for lb in view["load_balancers"]], [LB])
        self.assertEqual(view["load_balancers"][0]["waf"], ACL)
        self.assertTrue(view["warnings"])
        self.assert_no_mutation()
        self.assertFalse(any(s == "terraform" and op == "plan" for s, op, _ in self.runner.calls))

    def test_untagged_alb_skipped(self):
        self.runner.lb_tags[LB] = {}
        self.assertEqual(self.run_teardown()["load_balancers"], [])
        self.assert_no_mutation()

    def test_conflicting_project_tag_overrides_matching_controller_tags(self):
        self.runner.lb_tags[LB] = {**LB_TAGS, "Project": "other-project"}
        self.assertEqual(self.run_teardown()["load_balancers"], [])
        self.assert_no_mutation()

    def test_backend_without_lockfile_aborts_before_aws(self):
        metadata = self.root / "infra/environments/dev/.terraform/terraform.tfstate"
        data = json.loads(metadata.read_text())
        data["backend"]["config"]["use_lockfile"] = False
        metadata.write_text(json.dumps(data))
        with self.assertRaises(teardown.UnsafeTeardown):
            self.run_teardown(True, CONFIRM="DESTROY")
        self.assertEqual(self.runner.calls, [])

    def test_foreign_waf_blocks_before_any_mutation(self):
        self.runner.acl = ACL.replace("food-delivery-dev-waf", "other-project")
        with self.assertRaises(teardown.UnsafeTeardown):
            self.run_teardown(True, CONFIRM="DESTROY")
        self.assert_no_mutation()

    def test_foreign_or_missing_waf_tags_blocks(self):
        for actual in ({}, {**TAGS, "Project": "other"}):
            self.runner.acl_tags = actual
            with self.assertRaises(teardown.UnsafeTeardown):
                self.run_teardown()
        self.assert_no_mutation()

    def test_wrong_account_aborts(self):
        self.runner.account = "999999999999"
        with self.assertRaises(teardown.UnsafeTeardown):
            self.run_teardown(True, CONFIRM="DESTROY")
        self.assert_no_mutation()

    def test_wrong_region_aborts_before_aws(self):
        with self.assertRaises(teardown.UnsafeTeardown):
            self.run_teardown(True, CONFIRM="DESTROY", AWS_REGION="ap-northeast-1")
        self.assertEqual(self.runner.calls, [])

    def test_unsafe_environment_overrides_abort_before_aws(self):
        for environ in ({"TF_DATA_DIR": "/tmp/foreign-state"}, {"TF_CLI_ARGS_plan": "-target=foreign"},
                        {"SKIP_TF": "1"}, {"APP_NS": "foreign-app"}):
            with self.subTest(environ=environ):
                with self.assertRaises(teardown.UnsafeTeardown):
                    self.run_teardown(True, CONFIRM="DESTROY", **environ)
        self.assertEqual(self.runner.calls, [])

    def test_wrong_workspace_and_backend_aborts(self):
        self.runner.workspace = "prod"
        with self.assertRaises(teardown.UnsafeTeardown):
            self.run_teardown()
        self.assert_no_mutation()
        with self.assertRaises(teardown.UnsafeTeardown):
            self.run_teardown(STATE_KEY="terraform/prod/terraform.tfstate")

    def test_bootstrap_root_forbidden(self):
        with self.assertRaises(teardown.UnsafeTeardown):
            self.run_teardown(TF_DIR=str(self.root / "infra/bootstrap"))
        self.assertEqual(self.runner.calls, [])

    def test_persistent_resources_never_targeted_even_in_dev_state(self):
        for kind, values in (("aws_s3_bucket", {"id": "persistent"}), ("aws_cloudtrail", {"id": "audit"}),
                             ("aws_accessanalyzer_analyzer", {"id": "external"}),
                             ("aws_iam_role", {"name": "github-actions-eks-deploy-role"}),
                             ("aws_iam_openid_connect_provider", {"url": "https://token.actions.githubusercontent.com"})):
            with self.subTest(kind=kind):
                self.runner = FakeRunner()
                self.runner.state["values"]["root_module"]["resources"] = [resource("module.eks.test.persistent", kind, **values)]
                with self.assertRaises(teardown.UnsafeTeardown):
                    self.run_teardown(True, CONFIRM="DESTROY")
                self.assert_no_mutation()

    def test_wrong_kube_endpoint_and_foreign_application_abort(self):
        self.runner.context_endpoint = "https://foreign.example"
        with self.assertRaises(teardown.UnsafeTeardown):
            self.run_teardown(True, CONFIRM="DESTROY")
        self.assert_no_mutation()
        self.runner.context_endpoint = "https://own.example"
        self.runner.argo_repo = "https://github.com/other/project.git"
        with self.assertRaises(teardown.UnsafeTeardown):
            self.run_teardown(True, CONFIRM="DESTROY")
        self.assert_no_mutation()

    def test_foreign_ecr_never_force_deleted(self):
        self.runner.ecr_tags = {**TAGS, "Project": "other"}
        with self.assertRaises(teardown.UnsafeTeardown):
            self.run_teardown(True, CONFIRM="DESTROY")
        self.assert_no_mutation()

    def test_owned_waf_disassociated_only_for_verified_alb(self):
        state = teardown.resources(self.runner.state)
        view = teardown.inventory(self.runner, state)
        # No kube mutation in this isolated path; simulate Controller deletion during wait.
        def advance(_):
            self.runner.kube_deleted = True
        teardown.reclaim(self.runner, state, view, None, sleep=advance)
        calls = [args for service, op, args in self.runner.calls if op == "disassociate-web-acl"]
        self.assertEqual(calls, [("--resource-arn", LB)])

    def test_unknown_cleanup_candidates_block_execution(self):
        with self.assertRaises(teardown.UnsafeTeardown):
            self.run_teardown(True, CONFIRM="DESTROY")
        self.assert_no_mutation()

    def test_saved_destroy_plan_rejects_create_foreign_and_persistent(self):
        state = teardown.resources(self.runner.state)
        for address, kind, actions, before in ((next(iter(state)), "aws_vpc", ["create"], {}),
                                             ("module.eks.unknown", "aws_iam_role", ["delete"], {}),
                                             (next(iter(state)), "aws_cloudtrail", ["delete"], {})):
            with self.assertRaises(teardown.UnsafeTeardown):
                teardown.validate_destroy_plan({"resource_changes": [{"address": address, "mode": "managed", "type": kind,
                                               "change": {"actions": actions, "before": before}}]}, state)

    def test_owned_success_uses_only_saved_destroy_plan_and_no_state_rm(self):
        self.runner.candidates = [LB]
        self.run_teardown(True, CONFIRM="DESTROY")
        plans = [args for svc, op, args in self.runner.calls if svc == "terraform" and op == "plan"]
        applies = [args for svc, op, args in self.runner.calls if svc == "terraform" and op == "apply"]
        self.assertEqual(len(plans), 1)
        self.assertEqual(applies[0][-1], next(arg.removeprefix("-out=") for arg in plans[0] if arg.startswith("-out=")))
        self.assertFalse(any(op in {"state", "delete-repository", "delete-network-interface", "detach-role-policy"}
                             for _, op, _ in self.runner.calls))

    def test_owned_ssh_application_preserves_saved_plan_cleanup_contract(self):
        self.runner.argo_repo = "git@github.com:jx-dohwan/food-delivery-eks-platform.git"
        self.runner.candidates = [LB]
        self.run_teardown(True, CONFIRM="DESTROY")
        self.assertTrue(self.runner.after_apply)  # FakeRunner only; never a real Terraform call.
        plans = [args for svc, op, args in self.runner.calls if svc == "terraform" and op == "plan"]
        applies = [args for svc, op, args in self.runner.calls if svc == "terraform" and op == "apply"]
        self.assertEqual(len(plans), 1)
        self.assertEqual(len(applies), 1)
        self.assertEqual(applies[0][-1], next(arg.removeprefix("-out=") for arg in plans[0] if arg.startswith("-out=")))
        self.assertFalse(any(op in {"state", "delete-repository", "delete-load-balancer"}
                             for _, op, _ in self.runner.calls))

    def test_empty_state_no_cleanup(self):
        self.runner.state = {}
        self.run_teardown(True, CONFIRM="DESTROY")
        self.assert_no_mutation()

    def test_application_finalizer_already_deleted_ingress(self):
        self.runner.candidates = [LB]
        self.runner.cascade_ingress_deleted = True
        self.run_teardown(True, CONFIRM="DESTROY")
        self.assertTrue(self.runner.after_apply)
        self.assertFalse(any(svc == "kubectl" and op == "annotate" for svc, op, _ in self.runner.calls))

    def test_controller_timeout_never_force_deletes_any_lb(self):
        self.runner.candidates = [LB]
        self.runner.missing_after_reclaim = False
        with self.assertRaises(teardown.UnsafeTeardown):
            self.run_teardown(True, CONFIRM="DESTROY", WAIT_SECONDS="0")
        self.assertFalse(self.runner.after_apply)
        self.assertFalse(any(op == "delete-load-balancer" for _, op, _ in self.runner.calls))

    def test_non_was_web_repository_address_forbidden(self):
        with self.assertRaises(teardown.UnsafeTeardown):
            teardown.validate_resource('module.ecr.aws_ecr_repository.this["other"]', "aws_ecr_repository", {"name": "other"})

    def test_stale_plan_identity_rejected(self):
        state = teardown.resources(self.runner.state)
        address = "module.network.aws_vpc.this"
        before = {**state[address]["values"], "id": "vpc-foreign"}
        with self.assertRaises(teardown.UnsafeTeardown):
            teardown.validate_destroy_plan({"resource_changes": [{"address": address, "mode": "managed", "type": "aws_vpc",
                "change": {"actions": ["delete"], "before": before}}]}, state)

    def test_ingress_points_to_unverified_lb_or_foreign_acl(self):
        self.runner.candidates = []
        self.runner.ingress_hostname = "foreign.example.com"
        with self.assertRaises(teardown.UnsafeTeardown):
            self.run_teardown(True, CONFIRM="DESTROY")
        self.assert_no_mutation()
        self.runner.ingress_hostname = None
        self.runner.ingress_waf = ACL.replace("food-delivery-dev-waf", "foreign")
        with self.assertRaises(teardown.UnsafeTeardown):
            self.run_teardown(True, CONFIRM="DESTROY")
        self.assert_no_mutation()

    def test_command_errors_never_expose_arbitrary_stderr(self):
        from subprocess import CompletedProcess
        result = CompletedProcess(["terraform"], 1, stdout="", stderr="Invalid secret (PASSWORD_SECRET) webhook SECRET_URL")
        with patch.object(teardown.subprocess, "run", return_value=result):
            with self.assertRaises(teardown.CommandFailed) as caught:
                teardown.Runner().run(["terraform", "plan"])
        self.assertNotIn("SECRET", str(caught.exception))

    def test_missing_confirmation_aborts_before_reads(self):
        with self.assertRaises(teardown.UnsafeTeardown):
            self.run_teardown(True)
        self.assertEqual(self.runner.calls, [])


class RepositoryIdentityBoundaryTest(unittest.TestCase):
    """Exercise the real ownership guard through a read-only in-memory runner."""

    def application(self, repo):
        return {"spec": {"source": {"repoURL": repo, "targetRevision": "main",
                                    "path": "k8s/overlays/dev"},
                         "destination": {"namespace": "app", "server": "https://kubernetes.default.svc"}}}

    def inspect(self, application):
        class ReadOnlyFixture:
            def __init__(self):
                self.calls = []

            def kube(self, context, *args, structured=False):
                self.calls.append(args)
                if args == ("config", "view", "--raw", "--minify", "-o", "json"):
                    return {"clusters": [{"cluster": {"server": "https://local-fixture.invalid",
                                                       "certificate-authority-data": "SYNTHETIC-CA"}}]}
                if args == ("get", "crd", "applications.argoproj.io", "--ignore-not-found", "-o", "name"):
                    return "customresourcedefinition.apiextensions.k8s.io/applications.argoproj.io"
                if args == ("get", "application", "food-delivery-dev", "-n", "argocd",
                            "--ignore-not-found", "-o", "json"):
                    return json.dumps(application)
                if args == ("get", "ingress", "main-ingress", "-n", "app",
                            "--ignore-not-found", "-o", "json"):
                    return ""
                raise AssertionError("External/mutating operation forbidden")

        runner = ReadOnlyFixture()
        try:
            return teardown.kube_objects(runner, {"arn": "LOCAL-FIXTURE",
                "endpoint": "https://local-fixture.invalid", "certificateAuthority": {"data": "SYNTHETIC-CA"}})
        finally:
            self.assertTrue(all(call[0] in {"config", "get"} for call in runner.calls))

    def test_exact_project_https_and_scp_ssh_allowed(self):
        for repo in ("https://github.com/jx-dohwan/food-delivery-eks-platform.git",
                     "https://github.com/jx-dohwan/food-delivery-eks-platform",
                     "git@github.com:jx-dohwan/food-delivery-eks-platform.git",
                     "git@github.com:jx-dohwan/food-delivery-eks-platform"):
            with self.subTest(repo=repo):
                _, objects = self.inspect(self.application(repo))
                self.assertIn("application", objects)

    def test_actual_argocd_source_repo_allowed(self):
        # Read the actual scalar, rather than repeating the historical HTTPS fixture.
        lines = (Path(__file__).resolve().parents[1] / "argocd-app.yaml").read_text().splitlines()
        values = [line.split(":", 1)[1].strip().strip("'\"")
                  for line in lines if line.lstrip().startswith("repoURL:")]
        self.assertEqual(len(values), 1)
        self.assertEqual(values[0], "git@github.com:jx-dohwan/food-delivery-eks-platform.git")
        self.inspect(self.application(values[0]))

    def test_foreign_host_owner_repository_and_ssh_uri_rejected(self):
        for repo in ("https://github.com/other/food_delivery_eks.git",
                     "git@github.com:other/food_delivery_eks.git",
                     "https://github.com/jx-dohwan/other.git",
                     "git@github.com:jx-dohwan/other.git",
                     "https://gitlab.com/jx-dohwan/food-delivery-eks-platform.git",
                     "git@gitlab.com:jx-dohwan/food-delivery-eks-platform.git",
                     "https://github.com.evil.invalid/jx-dohwan/food-delivery-eks-platform.git",
                     "git@github.com.evil.invalid:jx-dohwan/food-delivery-eks-platform.git",
                     "ssh://git@github.com/jx-dohwan/food-delivery-eks-platform.git",
                     "git://github.com/jx-dohwan/food-delivery-eks-platform.git"):
            with self.subTest(repo=repo):
                with self.assertRaises(teardown.UnsafeTeardown):
                    self.inspect(self.application(repo))

    def test_ambiguous_path_encoding_credentials_query_and_control_chars_rejected(self):
        for repo in ("https://github.com/jx-dohwan/food-delivery-eks-platform.git/",
                     "https://github.com/jx-dohwan/food-delivery-eks-platform.git.git",
                     "https://github.com/jx-dohwan/../jx-dohwan/food-delivery-eks-platform.git",
                     "git@github.com:jx-dohwan//food_delivery_eks.git",
                     "https://github.com/jx-dohwan%2Ffood_delivery_eks.git",
                     "https://github.com/jx-dohwan/%66ood_delivery_eks.git",
                     "https://github.com/jx-dohwan/food-delivery-eks-platform.git?ref=main",
                     "git@github.com:jx-dohwan/food-delivery-eks-platform.git#main",
                     "https://synthetic:credential@github.com/jx-dohwan/food-delivery-eks-platform.git",
                     "https://github.com@evil.invalid/jx-dohwan/food-delivery-eks-platform.git",
                     "https://evil.invalid@github.com/jx-dohwan/food-delivery-eks-platform.git",
                     "https://git@github.com/jx-dohwan/food-delivery-eks-platform.git",
                     "other@github.com:jx-dohwan/food-delivery-eks-platform.git",
                     "git@github.com:22/jx-dohwan/food-delivery-eks-platform.git",
                     "https://github.com:443/jx-dohwan/food-delivery-eks-platform.git",
                     "HTTPS://github.com/jx-dohwan/food-delivery-eks-platform.git",
                     "https://github.com/JX-DOHWAN/food_delivery_eks.git",
                     "git@github.com:jx-dohwan/food-delivery-eks-platform.git\n",
                     " git@github.com:jx-dohwan/food-delivery-eks-platform.git",
                     "git@github.com:jx-dohwan/food-delivery-eks-platform.git\x00"):
            with self.subTest(repo=repo):
                with self.assertRaises(teardown.UnsafeTeardown):
                    self.inspect(self.application(repo))

    def test_missing_empty_or_non_string_repo_fail_closed(self):
        for value in ("", " ", None, False, 123, [], {}):
            with self.subTest(type=type(value).__name__):
                with self.assertRaises(teardown.UnsafeTeardown):
                    self.inspect(self.application(value))
        app = self.application("unused")
        del app["spec"]["source"]["repoURL"]
        with self.assertRaises(teardown.UnsafeTeardown):
            self.inspect(app)

    def test_branch_path_namespace_and_server_guards_preserved_for_both_transports(self):
        for repo in ("https://github.com/jx-dohwan/food-delivery-eks-platform.git",
                     "git@github.com:jx-dohwan/food-delivery-eks-platform.git"):
            for section, key, value in (("source", "targetRevision", "other"),
                                        ("source", "path", "k8s/overlays/prod"),
                                        ("destination", "namespace", "other"),
                                        ("destination", "server", "https://foreign.invalid")):
                for missing in (False, True):
                    with self.subTest(repo=repo, key=key, missing=missing):
                        app = copy.deepcopy(self.application(repo))
                        if missing:
                            del app["spec"][section][key]
                        else:
                            app["spec"][section][key] = value
                        with self.assertRaises(teardown.UnsafeTeardown):
                            self.inspect(app)


class NewWorkloadIdentityBoundaryTest(unittest.TestCase):
    def test_was_collector_roles_are_dev_ephemeral_but_bootstrap_is_still_forbidden(self):
        for role in ("was", "adot_collector"):
            teardown.validate_resource("module.eks.aws_iam_role." + role, "aws_iam_role", {
                "arn": "arn:aws:iam::123456789012:role/project-dev-" + role,
                "tags": TAGS,
            })
        with self.assertRaises(teardown.UnsafeTeardown):
            teardown.validate_resource("aws_iam_role.github_actions", "aws_iam_role", {})


if __name__ == "__main__":
    unittest.main()
