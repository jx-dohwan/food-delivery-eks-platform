#!/usr/bin/env python3
"""Dev-state-first teardown. Default: read-only inventory, never regional bulk delete."""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

def _private_identity(key, env_name):
    """Account-specific values never live in Git: environment first, then the git-ignored
    config/r2-dev-target.json. Missing values stay empty so every guarded action fails closed."""
    if os.environ.get(env_name):
        return os.environ[env_name]
    try:
        target = json.loads((Path(__file__).resolve().parents[1] / "config/r2-dev-target.json").read_text())
        return {"account_id": target.get("account_id", ""),
                "state_bucket": (target.get("archive_backend") or {}).get("bucket", "")}[key]
    except (OSError, ValueError, AttributeError):
        return ""


ACCOUNT = _private_identity("account_id", "FOOD_DELIVERY_ACCOUNT_ID")
STATE_BUCKET = _private_identity("state_bucket", "FOOD_DELIVERY_STATE_BUCKET")
REGION = "ap-northeast-2"
PROJECT = "food-delivery"
ENVIRONMENT = "dev"
ROOT = Path(__file__).resolve().parents[1]
DEV = ROOT / "infra/environments/dev"
STACK = "app/main-ingress"  # Actual repository Ingress is an implicit group.
KARPENTER_POOL = "food-delivery-app"
MODULES = {"network", "security_group", "eks", "ecr", "secrets_manager", "rds",
           "redis", "monitoring", "waf", "sg_auto_remediation"}


class UnsafeTeardown(RuntimeError):
    pass



class StorageOwnershipError(UnsafeTeardown):
    pass

def validate_manifest(manifest, pv_items, volume_items, *, account, region, cluster, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    expected = {'account': account, 'region': region, 'cluster': cluster, 'project': 'food-delivery', 'environment': 'dev'}
    if any(manifest.get(k) != v for k, v in expected.items()):
        raise StorageOwnershipError('Storage owner context mismatch')
    def retention(row):
        if not isinstance(row.get('owner'), str) or not row['owner'].strip():
            raise StorageOwnershipError('Explicit retention owner required')
        try: end = datetime.datetime.fromisoformat(row['retain_until'].replace('Z', '+00:00'))
        except (ValueError, KeyError, TypeError): raise StorageOwnershipError('Exact retention end required') from None
        if end.tzinfo is None or end <= now:
            raise StorageOwnershipError('Retention end must be future UTC-aware time')
    retention(manifest.get('bucket', {}))
    bucket = manifest['bucket'].get('name', '')
    if not re.fullmatch(r'food-delivery-loki-[a-z0-9-]+', bucket):
        raise StorageOwnershipError('Not a dedicated Loki archive')
    selected = [pv for pv in pv_items if pv.get('spec', {}).get('storageClassName') == 'logging-gp3']
    declared = manifest.get('volumes', [])
    if len({r.get('volume_id') for r in declared}) != len(declared) or len({r.get('pv') for r in declared}) != len(declared):
        raise StorageOwnershipError('Duplicate volume/PV declaration')
    if {r.get('pv') for r in declared} != {pv.get('metadata', {}).get('name') for pv in selected}:
        raise StorageOwnershipError('PV inventory differs from approved manifest')
    if len(volume_items) != len(declared) or len({v.get('VolumeId') for v in volume_items}) != len(volume_items):
        raise StorageOwnershipError('EC2 volume inventory mismatch')
    volumes = {v['VolumeId']: v for v in volume_items}
    for pv in selected:
        row = next(r for r in declared if r['pv'] == pv['metadata']['name']); retention(row)
        spec = pv['spec']; claim = spec.get('claimRef', {}); csi = spec.get('csi', {})
        if (spec.get('persistentVolumeReclaimPolicy') != 'Retain' or claim.get('namespace') != 'monitoring'
            or not claim.get('name', '').startswith('storage-loki-') or not claim.get('uid')
            or claim['name'] != row.get('pvc') or claim['uid'] != row.get('pvc_uid')
            or csi.get('driver') != 'ebs.csi.aws.com' or csi.get('volumeHandle') != row.get('volume_id')
            or not re.fullmatch(r'vol-[a-f0-9]{8,17}', row.get('volume_id', ''))):
            raise StorageOwnershipError('PV/claim/CSI identity mismatch')
        volume = volumes.get(row['volume_id'], {}); tags = {t['Key']: t['Value'] for t in volume.get('Tags', [])}
        required_tags = {'Project': 'food-delivery', 'Environment': 'dev', 'Cluster': cluster,
                         'Purpose': 'loki-wal', 'ebs.csi.aws.com/cluster': 'true',
                         'kubernetes.io/created-for/pvc/namespace': 'monitoring',
                         'kubernetes.io/created-for/pvc/name': row['pvc'],
                         'kubernetes.io/created-for/pv/name': row['pv']}
        if any(tags.get(k) != v for k, v in required_tags.items()) or volume.get('AvailabilityZone') != row.get('az'):
            raise StorageOwnershipError('EC2 volume owner/AZ mismatch')
        terms = spec.get('nodeAffinity', {}).get('required', {}).get('nodeSelectorTerms', [])
        if not terms or any(not any(e.get('key') in ('topology.ebs.csi.aws.com/zone', 'topology.kubernetes.io/zone')
            and e.get('operator') == 'In' and e.get('values') == [row['az']] for e in term.get('matchExpressions', [])) for term in terms):
            raise StorageOwnershipError('PV node affinity does not match exact volume AZ')
        actual = sorted(a.get('InstanceId') for a in volume.get('Attachments', []))
        if actual != sorted(row.get('instance_ids', [])):
            raise StorageOwnershipError('Volume attachment drift')
    return {'archive_bucket': bucket, 'retained_volume_ids': sorted(volumes), 'deletion_authorized': False}


def logging_bucket_from_policies(policies):
    if len(policies) != 1:
        raise UnsafeTeardown('Exact Loki archive IAM policy missing or ambiguous')
    bucket_resources = set()
    for statement in json.loads(policies[0]).get('Statement', []):
        resources = statement.get('Resource', [])
        for value in resources if isinstance(resources, list) else [resources]:
            match = re.fullmatch(r'arn:aws:s3:::(food-delivery-loki-[a-z0-9-]+)', str(value))
            if match: bucket_resources.add(match.group(1))
    if len(bucket_resources) != 1:
        raise UnsafeTeardown('Exact archive bucket ownership is ambiguous')
    return next(iter(bucket_resources))

def logging_storage_inventory(runner, context, cluster, bucket, environ):
    manifest_path = environ.get('LOGGING_RETENTION_MANIFEST')
    if not manifest_path:
        raise UnsafeTeardown('Central logging requires exact storage retention manifest before teardown')
    manifest = json.loads(Path(manifest_path).read_text())
    if manifest.get('bucket', {}).get('name') != bucket:
        raise UnsafeTeardown('Archive bucket differs from deployed values')
    pvs = runner.kube(context, 'get', 'pv', '-o', 'json', structured=True)['items']
    ids = [r.get('volume_id', '') for r in manifest.get('volumes', [])]
    if not all(re.fullmatch(r'vol-[a-f0-9]{8,17}', v) for v in ids):
        raise UnsafeTeardown('Invalid exact CSI volume identity')
    volumes = runner.aws('ec2', 'describe-volumes', '--volume-ids', *ids)['Volumes'] if ids else []
    archive_tags = tags(runner.aws('s3api', 'get-bucket-tagging', '--bucket', bucket, '--expected-bucket-owner', ACCOUNT)['TagSet'])
    if archive_tags.get('Project') != PROJECT or archive_tags.get('Purpose') != 'retained-loki-logs':
        raise UnsafeTeardown('Archive ownership tags mismatch')
    location = runner.aws('s3api', 'get-bucket-location', '--bucket', bucket, '--expected-bucket-owner', ACCOUNT).get('LocationConstraint')
    if location != REGION:
        raise UnsafeTeardown('Archive region differs from approved manifest')
    return validate_manifest(manifest, pvs, volumes, account=ACCOUNT, region=REGION, cluster=cluster)

class CommandFailed(UnsafeTeardown):
    def __init__(self, command, code="unknown"):
        self.code = code
        # Do not dump command arguments, state, plan, stderr or credentials.
        super().__init__(f"Command failed: {command}; code={code}. Inspect securely before retrying.")


class Runner:
    def run(self, args, structured=False):
        env = os.environ.copy()
        env["AWS_PAGER"] = ""
        env["AWS_REGION"] = REGION
        env["AWS_DEFAULT_REGION"] = REGION
        for old, new in (("TF_SLACK_WEBHOOK_URL", "TF_VAR_slack_webhook_url"),
                         ("TF_SLACK_ALERT_TAGS", "TF_VAR_slack_alert_tags")):
            if old in env:
                env[new] = env[old]
        result = subprocess.run(args, capture_output=True, text=True, env=env, check=False)
        if result.returncode:
            match = re.search(r"\(([A-Za-z0-9_.-]+)\)", result.stderr)
            allowed_codes = {"ResourceNotFoundException", "RepositoryNotFoundException", "LoadBalancerNotFound",
                             "WAFNonexistentItemException", "AccessDenied", "AccessDeniedException",
                             "InvalidVpcID.NotFound", "ExpiredToken", "InvalidClientTokenId"}
            code = match.group(1) if args[0] == "aws" and match and match.group(1) in allowed_codes else "nonzero_exit"
            raise CommandFailed(args[0], code)
        if structured:
            try:
                return json.loads(result.stdout)
            except ValueError:
                raise CommandFailed(args[0], "invalid_json") from None
        return result.stdout.strip()

    def aws(self, service, operation, *args):
        return self.run(["aws", service, operation, *args, "--region", REGION, "--output", "json"], True)

    def tf(self, *args, structured=False):
        return self.run(["terraform", f"-chdir={DEV}", *args], structured)

    def kube(self, context, *args, structured=False):
        return self.run(["kubectl", "--context", context, *args], structured)


def tags(values):
    if isinstance(values, dict):
        return values
    return {tag["Key"]: tag["Value"] for tag in values or []}


def project_tags(values):
    actual = tags(values)
    return all(actual.get(k) == v for k, v in {
        "Project": PROJECT, "Environment": ENVIRONMENT, "ManagedBy": "terraform"}.items())


def resources(document):
    def walk(module):
        yield from (r for r in module.get("resources", []) if r.get("mode") == "managed")
        for child in module.get("child_modules", []):
            yield from walk(child)
    return {r["address"]: r for r in walk(document.get("values", {}).get("root_module", {}))}


def validate_resource(address, kind, values):
    module = re.match(r"module\.([a-z_]+)\.", address)
    if not (module and module.group(1) in MODULES) and address not in {
            "aws_route53_record.dev_app[0]", "aws_route53_record.www_app[0]"}:
        raise UnsafeTeardown(f"Unrecognized dev-state address: {address}")
    if kind.startswith("aws_s3_") or kind in {"aws_cloudtrail", "aws_accessanalyzer_analyzer"}:
        raise UnsafeTeardown("Persistent resources found in dev state; migration review required")
    if kind in {"aws_ecr_repository", "aws_ecr_lifecycle_policy"} and not re.fullmatch(
            rf'module\.ecr\.{kind}\.this\["(?:was|web)"\]', address):
        raise UnsafeTeardown("Only the WAS/Web ECR resources in dev state may be destroyed")
    if ("github_actions" in address or values.get("name") == "github-actions-eks-deploy-role"
            or values.get("role") == "github-actions-eks-deploy-role"
            or values.get("role_name") == "github-actions-eks-deploy-role"
            or str(values.get("url", "")).removeprefix("https://").rstrip("/") == "token.actions.githubusercontent.com"):
        raise UnsafeTeardown("Persistent GitHub identity found in dev state")
    arn = values.get("arn", "")
    if isinstance(arn, str) and arn.startswith("arn:"):
        parts = arn.split(":", 5)
        if len(parts) != 6 or parts[1] != "aws" or parts[3] not in ("", REGION) or parts[4] not in ("", ACCOUNT):
            raise UnsafeTeardown(f"Foreign account/region ARN in {address}")
    actual_tags = tags(values.get("tags", {}))
    for key, expected in (("Project", PROJECT), ("Environment", ENVIRONMENT), ("ManagedBy", "terraform")):
        if key in actual_tags and actual_tags[key] != expected:
            raise UnsafeTeardown(f"Foreign ownership tag in {address}")


def preflight(runner, environ, root=ROOT):
    expected = (root / "infra/environments/dev").resolve()
    if Path(environ.get("TF_DIR", expected)).resolve() != expected:
        raise UnsafeTeardown("Only infra/environments/dev is allowed; bootstrap/prod are forbidden")
    if Path(environ.get("TF_DATA_DIR", expected / ".terraform")).resolve() != expected / ".terraform":
        raise UnsafeTeardown("TF_DATA_DIR must refer to this dev backend metadata")
    if any(value for key, value in environ.items() if key.startswith("TF_CLI_ARGS")):
        raise UnsafeTeardown("Unset TF_CLI_ARGS overrides before teardown")
    if environ.get("SKIP_TF", "0") != "0":
        raise UnsafeTeardown("Legacy SKIP_TF is unsupported; use --dry-run")
    for key, value in (("APP_NS", "app"), ("INGRESS_NAME", "main-ingress"),
                       ("ARGOCD_NS", "argocd"), ("ARGOCD_APP", "food-delivery-dev")):
        if environ.get(key, value) != value:
            raise UnsafeTeardown("Kubernetes target overrides are forbidden")
    if any(environ.get(key, REGION) != REGION for key in ("AWS_REGION", "AWS_DEFAULT_REGION")):
        raise UnsafeTeardown("Only ap-northeast-2 is allowed")
    for key, value in (("STATE_BUCKET", STATE_BUCKET), ("STATE_KEY", "terraform/dev/terraform.tfstate")):
        if environ.get(key, value) != value:
            raise UnsafeTeardown("Only the dev backend is allowed")
    metadata = expected / ".terraform/terraform.tfstate"
    if not metadata.is_file():
        raise UnsafeTeardown("Missing initialized backend metadata; initialize and verify dev separately")
    backend = json.loads(metadata.read_text()).get("backend", {})
    config = backend.get("config", {})
    if (backend.get("type") != "s3" or not STATE_BUCKET or config.get("bucket") != STATE_BUCKET
            or config.get("key") != "terraform/dev/terraform.tfstate" or config.get("region") != REGION
            or config.get("use_lockfile") is not True):
        raise UnsafeTeardown("Initialized backend is not the expected dev state")
    if not re.fullmatch(r"[0-9]{12}", ACCOUNT):
        raise UnsafeTeardown("Target account is not configured (FOOD_DELIVERY_ACCOUNT_ID or private target)")
    identity = runner.aws("sts", "get-caller-identity")
    if identity.get("Account") != ACCOUNT or ":assumed-role/github-actions-eks-deploy-role/" in identity.get("Arn", ""):
        raise UnsafeTeardown("Wrong account or ECR-only CI identity; use the Terraform operator")
    if runner.tf("workspace", "show") != "default":
        raise UnsafeTeardown("Only the default dev workspace is allowed")
    state = resources(runner.tf("show", "-json", structured=True))
    for address, resource in state.items():
        validate_resource(address, resource["type"], resource.get("values", {}))
    return state


def owned_lb(lb, resource_tags, vpc_id, cluster_name):
    return (lb.get("VpcId") == vpc_id and lb.get("Type") == "application"
            and lb.get("LoadBalancerArn", "").startswith(f"arn:aws:elasticloadbalancing:{REGION}:{ACCOUNT}:loadbalancer/app/")
            and resource_tags.get("elbv2.k8s.aws/cluster") == cluster_name
            and resource_tags.get("ingress.k8s.aws/stack") == STACK
            and resource_tags.get("ingress.k8s.aws/resource") == "LoadBalancer"
            and resource_tags.get("Project", PROJECT) == PROJECT
            and resource_tags.get("Environment", ENVIRONMENT) == ENVIRONMENT)


def inspect_lb(runner, arn, vpc_id, cluster_name, strict=False):
    try:
        lbs = runner.aws("elbv2", "describe-load-balancers", "--load-balancer-arns", arn)["LoadBalancers"]
        if len(lbs) != 1:
            return None
        descriptions = runner.aws("elbv2", "describe-tags", "--resource-arns", arn)["TagDescriptions"]
        current_tags = tags(descriptions[0].get("Tags", [])) if len(descriptions) == 1 else {}
        if not owned_lb(lbs[0], current_tags, vpc_id, cluster_name):
            if strict:
                raise UnsafeTeardown("Load balancer ownership changed; skip and abort")
            return None
        return lbs[0]
    except CommandFailed as error:
        if error.code == "LoadBalancerNotFound":
            return None
        raise


def association(runner, lb_arn, state):
    try:
        acl = runner.aws("wafv2", "get-web-acl-for-resource", "--resource-arn", lb_arn).get("WebACL")
    except CommandFailed as error:
        if error.code == "WAFNonexistentItemException":
            return None
        raise
    if not acl:
        return None
    known = {r["values"].get("arn") for r in state.values() if r["type"] == "aws_wafv2_web_acl"}
    arn = acl.get("ARN")
    if arn not in known:
        raise UnsafeTeardown("Foreign/unmanaged WAF association: skip and block teardown")
    live = runner.aws("wafv2", "list-tags-for-resource", "--resource-arn", arn)
    if not project_tags(live.get("TagInfoForResource", {}).get("TagList", [])):
        raise UnsafeTeardown("WAF ownership tags are missing/foreign: skip and block teardown")
    return arn


def inventory(runner, state):
    if not state:
        return {"resources": [], "load_balancers": [], "cluster": None, "vpc_id": None, "warnings": []}
    vpc = state.get("module.network.aws_vpc.this", {}).get("values", {})
    vpc_id = vpc.get("id")
    if not isinstance(vpc_id, str) or not re.fullmatch(r"vpc-(?:[0-9a-f]{8}|[0-9a-f]{17})", vpc_id):
        raise UnsafeTeardown("Cannot prove the dev VPC from state; no name-based fallback")
    vpcs = runner.aws("ec2", "describe-vpcs", "--vpc-ids", vpc_id).get("Vpcs", [])
    if len(vpcs) != 1 or vpcs[0].get("OwnerId") != ACCOUNT or vpcs[0].get("IsDefault") is not False:
        raise UnsafeTeardown("Dev VPC account/default status cannot be verified")
    cluster = state.get("module.eks.aws_eks_cluster.this", {}).get("values", {})
    cluster_name = cluster.get("name")
    warnings, lbs = [], []
    live_cluster = None
    if cluster_name:
        try:
            live_cluster = runner.aws("eks", "describe-cluster", "--name", cluster_name)["cluster"]
        except CommandFailed as error:
            if error.code != "ResourceNotFoundException":
                raise
        if live_cluster and (live_cluster.get("arn") != cluster.get("arn")
                             or live_cluster.get("resourcesVpcConfig", {}).get("vpcId") != vpc_id
                             or not project_tags(live_cluster.get("tags", {}))):
            raise UnsafeTeardown("EKS identity/VPC/ownership mismatch")
        candidates = runner.aws("resourcegroupstaggingapi", "get-resources",
                                "--resource-type-filters", "elasticloadbalancing:loadbalancer",
                                "--tag-filters", f"Key=elbv2.k8s.aws/cluster,Values={cluster_name}",
                                f"Key=ingress.k8s.aws/stack,Values={STACK}")
        for candidate in candidates.get("ResourceTagMappingList", []):
            arn = candidate["ResourceARN"]
            lb = inspect_lb(runner, arn, vpc_id, cluster_name)
            if not lb:
                warnings.append("Skipped ambiguous/foreign load balancer candidate")
                continue
            lbs.append({"arn": arn, "dns": lb.get("DNSName"), "waf": association(runner, arn, state)})
    else:
        # A partly removed cluster loses the controller ownership anchor. Do not
        # discover another cluster by name or silently claim all VPC resources.
        warnings.append("No cluster in state; runtime orphan cleanup is not attempted")
    for resource in state.values():
        if resource["type"] != "aws_ecr_repository":
            continue
        values = resource["values"]
        component = re.fullmatch(r'module\.ecr\.aws_ecr_repository\.this\["(was|web)"\]', resource["address"]).group(1)
        prefix = cluster_name.removesuffix("cluster") if cluster_name and cluster_name.endswith("cluster") else ""
        if values.get("name") != prefix + component:
            raise UnsafeTeardown("ECR repository name does not match the state-backed cluster prefix and WAS/Web component")
        try:
            live = runner.aws("ecr", "describe-repositories", "--repository-names", values["name"])["repositories"]
        except CommandFailed as error:
            if error.code == "RepositoryNotFoundException":
                continue
            raise
        if len(live) != 1 or live[0].get("repositoryArn") != values.get("arn"):
            raise UnsafeTeardown("ECR identity mismatch")
        if not project_tags(runner.aws("ecr", "list-tags-for-resource", "--resource-arn", values["arn"]).get("tags", [])):
            raise UnsafeTeardown("ECR ownership is missing/foreign; will not force-delete")
    view = {"resources": sorted(state), "load_balancers": lbs, "cluster": live_cluster,
            "vpc_id": vpc_id, "warnings": warnings}
    if any("karpenter" in address for address in state):
        if not live_cluster:
            raise UnsafeTeardown("Karpenter state without a live cluster: inspect nodes before destroy")
        view["karpenter_instances"] = karpenter_instances(runner, view)
    return view


def karpenter_instances(runner, view):
    """Discover only state-backed VPC/cluster/pool instances, never by name."""
    cluster_name = view["cluster"]["name"]
    response = runner.aws("ec2", "describe-instances", "--filters",
                          f"Name=vpc-id,Values={view['vpc_id']}",
                          f"Name=tag:kubernetes.io/cluster/{cluster_name},Values=owned",
                          f"Name=tag:karpenter.sh/nodepool,Values={KARPENTER_POOL}",
                          "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down")
    found = []
    for reservation in response.get("Reservations", []):
        if reservation.get("OwnerId") != ACCOUNT:
            raise UnsafeTeardown("Karpenter EC2 account ownership mismatch")
        for instance in reservation.get("Instances", []):
            actual = tags(instance.get("Tags", []))
            if (instance.get("VpcId") != view["vpc_id"] or not project_tags(actual)
                    or actual.get(f"kubernetes.io/cluster/{cluster_name}") != "owned"
                    or actual.get("karpenter.sh/nodepool") != KARPENTER_POOL
                    or actual.get("food-delivery/cluster") != cluster_name):
                raise UnsafeTeardown("Ambiguous/foreign Karpenter instance: abort, never force terminate")
            found.append(instance["InstanceId"])
    return sorted(found)


# A partial destroy can remove these CRDs; `get --ignore-not-found` still fails
# when the resource type itself is gone, so probe the CRD first.
OPTIONAL_CRDS = {
    "application": "applications.argoproj.io",
    "nodepool.karpenter.sh": "nodepools.karpenter.sh",
    "nodeclaims.karpenter.sh": "nodeclaims.karpenter.sh",
    "ec2nodeclass.karpenter.k8s.aws": "ec2nodeclasses.karpenter.k8s.aws",
}


def crd_installed(runner, context, kind):
    crd = OPTIONAL_CRDS.get(kind)
    return not crd or bool(runner.kube(context, "get", "crd", crd, "--ignore-not-found", "-o", "name"))


def check_karpenter_pool(obj):
    labels = obj.get("metadata", {}).get("labels", {})
    if (obj.get("apiVersion") != "karpenter.sh/v1" or obj.get("kind") != "NodePool"
            or obj.get("metadata", {}).get("name") != KARPENTER_POOL
            or labels.get("app.kubernetes.io/part-of") != "food-delivery"
            or labels.get("food-delivery/environment") != ENVIRONMENT
            or obj.get("spec", {}).get("template", {}).get("spec", {}).get("nodeClassRef") != {
                "group": "karpenter.k8s.aws", "kind": "EC2NodeClass", "name": KARPENTER_POOL}):
        raise UnsafeTeardown("Karpenter NodePool ownership/reference mismatch")


def reclaim_karpenter(runner, view, context_objects, wait_seconds, sleep):
    if "karpenter_instances" not in view:
        return
    if not context_objects:
        raise UnsafeTeardown("Verified Kubernetes context is required for Karpenter cleanup")
    context = context_objects[0]
    current = ""
    if crd_installed(runner, context, "nodepool.karpenter.sh"):
        current = runner.kube(context, "get", "nodepool.karpenter.sh", KARPENTER_POOL,
                              "--ignore-not-found", "-o", "json")
    if current:
        obj = json.loads(current)
        check_karpenter_pool(obj)
        # Controller stays on MNG and remains running until Terraform destroys it.
        # Do not force-delete finalizers or terminate instances outside Karpenter.
        runner.kube(context, "delete", "nodepool.karpenter.sh", KARPENTER_POOL,
                    "--ignore-not-found", "--wait=false")
    claims_crd = crd_installed(runner, context, "nodeclaims.karpenter.sh")
    elapsed = 0
    while True:
        claims = {"items": []}
        if claims_crd:
            claims = runner.kube(context, "get", "nodeclaims.karpenter.sh", "-l",
                                 f"karpenter.sh/nodepool={KARPENTER_POOL}", "-o", "json", structured=True)
        if not claims.get("items", []) and not karpenter_instances(runner, view):
            break
        if elapsed >= wait_seconds:
            raise UnsafeTeardown("Karpenter nodes still exist: abort before destroying controller/IAM/VPC")
        sleep(10)
        elapsed += 10
    # The EC2NodeClass termination finalizer calls IAM/EC2 from the controller.
    # Finish it now, while NAT egress and the controller still exist; once
    # Terraform removes NAT first, the finalizer can never complete.
    if not crd_installed(runner, context, "ec2nodeclass.karpenter.k8s.aws"):
        return
    runner.kube(context, "delete", "ec2nodeclass.karpenter.k8s.aws", KARPENTER_POOL,
                "--ignore-not-found", "--wait=false")
    elapsed = 0
    while runner.kube(context, "get", "ec2nodeclass.karpenter.k8s.aws", KARPENTER_POOL,
                      "--ignore-not-found", "-o", "name"):
        if elapsed >= wait_seconds:
            raise UnsafeTeardown("EC2NodeClass finalizer did not finish: abort before destroying NAT/controller")
        sleep(10)
        elapsed += 10


def validate_destroy_plan(plan, state):
    if not plan.get("applyable", True) or plan.get("errored", False):
        raise UnsafeTeardown("Destroy plan is not applyable")
    for change in plan.get("resource_changes", []):
        if change.get("mode") != "managed":
            continue
        actions = change["change"]["actions"]
        if actions == ["no-op"]:
            continue
        address = change["address"]
        before = change["change"].get("before") or {}
        if actions != ["delete"] or address not in state:
            raise UnsafeTeardown("Unexpected non-delete/out-of-state action in destroy plan")
        validate_resource(address, change["type"], before)
        if change["type"] != state[address]["type"]:
            raise UnsafeTeardown("Resource type differs from the reviewed state")
        for key in ("id", "arn"):
            if state[address].get("values", {}).get(key) != before.get(key):
                raise UnsafeTeardown("Resource identity drift: review a fresh inventory")


def is_project_repository(repo_url):
    """Only exact HTTPS and the configured SCP-style SSH identity are trusted.

    Do not decode, trim, case-fold or parse ambiguous userinfo/path spellings.
    An optional terminal .git suffix is the only normalization supported.
    """
    return isinstance(repo_url, str) and repo_url.removesuffix(".git") in {
        "https://github.com/jx-dohwan/food-delivery-eks-platform",
        "git@github.com:jx-dohwan/food-delivery-eks-platform",
    }


def kube_objects(runner, cluster):
    context = cluster["arn"]
    config = runner.kube(context, "config", "view", "--raw", "--minify", "-o", "json", structured=True)
    target = config.get("clusters", [])
    if (len(target) != 1 or target[0].get("cluster", {}).get("server") != cluster.get("endpoint")
            or target[0].get("cluster", {}).get("certificate-authority-data") != cluster.get("certificateAuthority", {}).get("data")):
        raise UnsafeTeardown("kubeconfig does not match the verified dev cluster endpoint/CA")
    found = {}
    for kind, name, namespace in (("application", "food-delivery-dev", "argocd"), ("ingress", "main-ingress", "app")):
        if not crd_installed(runner, context, kind):
            continue
        response = runner.kube(context, "get", kind, name, "-n", namespace, "--ignore-not-found", "-o", "json")
        if not response:
            continue
        obj = json.loads(response)
        if kind == "application":
            spec = obj.get("spec", {})
            source, destination = spec.get("source", {}), spec.get("destination", {})
            if (not is_project_repository(source.get("repoURL"))
                    or source.get("targetRevision") != "main" or source.get("path") != "k8s/overlays/dev"
                    or destination.get("namespace") != "app" or destination.get("server") != "https://kubernetes.default.svc"):
                raise UnsafeTeardown("ArgoCD Application source/destination is not this project")
        else:
            annotations = obj.get("metadata", {}).get("annotations", {})
            if (obj.get("spec", {}).get("ingressClassName") != "alb"
                    or annotations.get("alb.ingress.kubernetes.io/group.name")):
                raise UnsafeTeardown("Ingress ownership/group is ambiguous")
        found[kind] = obj
    return context, found


def reclaim(runner, state, view, context_objects, wait_seconds=600, sleep=time.sleep):
    cluster_name = view["cluster"]["name"] if view["cluster"] else None
    for candidate in view["load_balancers"]:
        if inspect_lb(runner, candidate["arn"], view["vpc_id"], cluster_name, strict=True):
            association(runner, candidate["arn"], state)
    if context_objects:
        context, objects = context_objects
        # Delete the verified Application first so selfHeal cannot recreate Ingress.
        if "application" in objects:
            runner.kube(context, "delete", "application", "food-delivery-dev", "-n", "argocd",
                        "--ignore-not-found", "--wait=true", "--timeout=180s")
        if "ingress" in objects:
            # The Application's finalizer may already have deleted the Ingress.
            current = runner.kube(context, "get", "ingress", "main-ingress", "-n", "app",
                                  "--ignore-not-found", "-o", "json")
            if not current:
                objects = {key: value for key, value in objects.items() if key != "ingress"}
            else:
                current = json.loads(current)
                if (current.get("spec", {}).get("ingressClassName") != "alb"
                        or current.get("metadata", {}).get("annotations", {}).get("alb.ingress.kubernetes.io/group.name")):
                    raise UnsafeTeardown("Ingress ownership changed before reclaim")
        if "ingress" in objects:
            # This controller-owned association is disabled only after ACL ownership was checked.
            if any(lb["waf"] for lb in view["load_balancers"]):
                runner.kube(context, "annotate", "ingress", "main-ingress", "-n", "app",
                            "alb.ingress.kubernetes.io/wafv2-acl-arn=none", "--overwrite")
            runner.kube(context, "delete", "ingress", "main-ingress", "-n", "app",
                        "--ignore-not-found", "--wait=true", "--timeout=180s")
    for candidate in view["load_balancers"]:
        arn = candidate["arn"]
        # Revalidate live ownership at mutation time, not only from inventory.
        if not inspect_lb(runner, arn, view["vpc_id"], cluster_name, strict=True):
            continue  # Controller already reclaimed this exact resource.
        acl = association(runner, arn, state)
        if acl:
            runner.aws("wafv2", "disassociate-web-acl", "--resource-arn", arn)
        elapsed = 0
        while inspect_lb(runner, arn, view["vpc_id"], cluster_name, strict=True):
            if elapsed >= wait_seconds:
                # Do not fall back to a regional force delete. Current ownership
                # still needs human review if the Controller cannot reclaim it.
                raise UnsafeTeardown("Project ALB still exists; abort before Terraform destroy")
            sleep(10)
            elapsed += 10
    reclaim_karpenter(runner, view, context_objects, wait_seconds, sleep)


def run(runner, environ, execute=False, root=ROOT, sleep=time.sleep):
    if execute and environ.get("CONFIRM") != "DESTROY":
        raise UnsafeTeardown("Execution requires CONFIRM=DESTROY; default is read-only dry-run")
    state = preflight(runner, environ, root)
    view = inventory(runner, state)
    objects = kube_objects(runner, view["cluster"]) if view["cluster"] else None
    logging = [r for r in state.values() if r['type'] == 'helm_release' and r.get('values', {}).get('name') == 'loki']
    if logging:
        if len(logging) != 1 or not objects:
            raise UnsafeTeardown('Logging deployment identity or Kubernetes context missing')
        # Read the JSON IAM policy, not Helm's yamlencode string as JSON.
        policies = [r['values']['policy'] for address, r in state.items()
                    if address.endswith('aws_iam_role_policy.loki_s3[0]') and r['type'] == 'aws_iam_role_policy']
        bucket = logging_bucket_from_policies(policies)
        view['logging_storage'] = logging_storage_inventory(runner, objects[0], view['cluster']['name'], bucket, environ)
    if "karpenter_instances" in view and objects and crd_installed(runner, objects[0], "nodepool.karpenter.sh"):
        pool = runner.kube(objects[0], "get", "nodepool.karpenter.sh", KARPENTER_POOL,
                           "--ignore-not-found", "-o", "json")
        if pool:
            check_karpenter_pool(json.loads(pool))
    if objects and "ingress" in objects[1]:
        ingress = objects[1]["ingress"]
        hosts = {entry.get("hostname") for entry in ingress.get("status", {}).get("loadBalancer", {}).get("ingress", [])}
        known_hosts = {lb.get("dns") for lb in view["load_balancers"]}
        if None in hosts or not hosts.issubset(known_hosts):
            raise UnsafeTeardown("Ingress points to an unverified load balancer; skip and abort")
        annotated_acl = ingress.get("metadata", {}).get("annotations", {}).get("alb.ingress.kubernetes.io/wafv2-acl-arn")
        known_acls = {res["values"].get("arn") for res in state.values() if res["type"] == "aws_wafv2_web_acl"}
        if annotated_acl not in (None, "", "none") and annotated_acl not in known_acls:
            raise UnsafeTeardown("Ingress references a foreign/unmanaged Web ACL; skip and abort")
    print(json.dumps({"mode": "execute" if execute else "dry-run", "account": ACCOUNT, "region": REGION,
                      "vpc_id": view["vpc_id"], "terraform_resources": view["resources"],
                      "controller_load_balancers": view["load_balancers"],
                      "logging_storage": view.get("logging_storage"),
                      "kubernetes_resources": list(objects[1]) if objects else [],
                      "karpenter_instances": view.get("karpenter_instances", []), "warnings": view["warnings"]}, indent=2))
    if not execute or not state:
        return view
    if view["warnings"]:
        raise UnsafeTeardown("Ambiguous ownership/orphans: skip cleanup and review before executing")
    # Saved plan permissions are private; never print JSON containing secret values.
    with tempfile.TemporaryDirectory(prefix="food-dev-destroy-") as directory:
        saved = str(Path(directory) / "destroy.tfplan")
        runner.tf("plan", "-destroy", "-input=false", "-lock-timeout=0s", "-var=manage_ingress_alb_alias=false", f"-out={saved}")
        validate_destroy_plan(runner.tf("show", "-json", saved, structured=True), state)
        reclaim(runner, state, view, objects, int(environ.get("WAIT_SECONDS", "600")), sleep)
        runner.tf("apply", "-input=false", saved)
    remaining = resources(runner.tf("show", "-json", structured=True))
    if remaining:
        raise UnsafeTeardown("Dev state still has managed resources; inspect without broad cleanup")
    if view.get('logging_storage'):
        print(json.dumps({'retained_logging_storage': view['logging_storage'],
                          'follow_up_cleanup': 'Separate exact-resource approval required; archive was not destroyed'}))
    print("Dev teardown finished. Bootstrap persistent resources were not targeted.")
    return view


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", help="Read-only state/project inventory (default)")
    mode.add_argument("--execute", action="store_true", help="Execute reviewed dev-only destruction; CONFIRM=DESTROY required")
    args = parser.parse_args()
    try:
        run(Runner(), os.environ, execute=args.execute)
    except (UnsafeTeardown, ValueError, TypeError, AttributeError, KeyError, OSError):
        # Tracebacks / raw command errors can contain sensitive provider output.
        # UnsafeTeardown messages are deliberately limited to safe metadata.
        import sys
        error = sys.exc_info()[1]
        message = str(error) if isinstance(error, UnsafeTeardown) else "Invalid/missing configuration; inspect securely"
        print(f"STOP: {message}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
