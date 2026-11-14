#!/usr/bin/env python3
"""Karpenter IAM and Helm dependency contracts. No AWS writes or deploys; graph uses the initialized dev root.

KARPENTER_POLICY_JSON may point to the policy extracted from a Terraform MOCK plan.
KARPENTER_GRAPH may point to `terraform graph -type=plan` output. Without either,
use the source template's documented mock inputs and generate the graph locally.
The condition evaluator covers this policy's operators; AWS simulation and live
Karpenter validation remain separate checks, not claims made by these unit tests.
"""
import fnmatch
import json
import os
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
POOL = 'food-delivery-app'
CLUSTER = 'platform-test'
REGION = 'ap-northeast-2'
ACCOUNT = '123456789012'
PREFIX = f'arn:aws:ec2:{REGION}:{ACCOUNT}:'
REQ_POOL = 'aws:RequestTag/karpenter.sh/nodepool'
REQ_CLASS = 'aws:RequestTag/karpenter.k8s.aws/ec2nodeclass'
RES_POOL = 'aws:ResourceTag/karpenter.sh/nodepool'
RES_CLASS = 'aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass'


def source_policy():
    text = (ROOT / 'infra/modules/eks/karpenter/controller-policy.json.tftpl').read_text()
    subnets = [PREFIX + 'subnet/subnet-00000000000000001', PREFIX + 'subnet/subnet-00000000000000002']
    expression = '${join(", ", [for arn in subnet_arns : jsonencode(arn)])}'
    assert text.count(expression) == 1
    text = text.replace(expression, ', '.join(map(json.dumps, subnets)))
    values = dict(region=REGION, account_id=ACCOUNT, cluster_name=CLUSTER, node_class_name=POOL,
                  ami_id='ami-00000000000000001', node_role_arn=f'arn:aws:iam::{ACCOUNT}:role/test',
                  instance_profile_arn=f'arn:aws:iam::{ACCOUNT}:instance-profile/platform-test-karpenter',
                  legacy_instance_profile_arn=f'arn:aws:iam::{ACCOUNT}:instance-profile/{CLUSTER}_4432966060878740941',
                  node_sg_arn=PREFIX+'security-group/sg-00000000000000001',
                  cluster_sg_arn=PREFIX+'security-group/sg-00000000000000002')
    for key, value in values.items():
        text = text.replace('${'+key+'}', value)
    assert '${' not in text
    return json.loads(text)


def values(x):
    return x if isinstance(x, list) else [x]


def condition_matches(conditions, context):
    for operator, conditions_by_key in conditions.items():
        for key, expected in conditions_by_key.items():
            present = key in context
            actual = values(context[key]) if present else []
            if operator == 'Null':
                ok = (not present) == (str(expected).lower() == 'true')
            elif operator == 'ForAllValues:StringEquals':
                ok = all(v in values(expected) for v in actual)
            elif operator == 'StringEqualsIfExists' and not present:
                ok = True
            elif operator in ('StringEquals', 'StringEqualsIfExists'):
                ok = present and any(v in values(expected) for v in actual)
            elif operator == 'StringLike':
                ok = present and any(fnmatch.fnmatchcase(v, pattern) for v in actual for pattern in values(expected))
            else:
                raise AssertionError('Unsupported condition operator: '+operator)
            if not ok:
                return False
    return True


def allowed(policy, action, resource, context):
    # EC2's service authorization table lists ENIs for RunInstances, not for
    # CreateFleet itself. Fleet can tag an ENI via CreateTags, which is a distinct
    # action. This known unsupported pair must match AWS's implicitDeny result.
    # https://docs.aws.amazon.com/service-authorization/latest/reference/list_ec2.html
    if action == 'ec2:CreateFleet' and ':network-interface/' in resource:
        return False
    matches = [s for s in policy['Statement']
               if any(fnmatch.fnmatchcase(action.lower(), a.lower()) for a in values(s['Action']))
               and any(fnmatch.fnmatchcase(resource, p) for p in values(s['Resource']))
               and condition_matches(s.get('Condition', {}), context)]
    return any(s['Effect'] == 'Allow' for s in matches) and not any(s['Effect'] == 'Deny' for s in matches)


def tag_context(pool=POOL, resource=False):
    base = 'aws:ResourceTag/' if resource else 'aws:RequestTag/'
    return {base+'kubernetes.io/cluster/'+CLUSTER:'owned', base+'eks:eks-cluster-name':CLUSTER,
            base+'karpenter.k8s.aws/ec2nodeclass':POOL, base+'karpenter.sh/nodepool':pool}


def policy_cases():
    """Action/resource pairs checked by both the local model and AWS custom simulation."""
    cases = []
    for name, pool in [('normal', POOL), ('validation', '')]:
        ctx = tag_context(pool)
        cases.append((name+'-template-create', 'ec2:CreateLaunchTemplate', PREFIX+'launch-template/lt-00000000000000001', ctx, True))
        for action in ('RunInstances', 'CreateFleet', 'CreateLaunchTemplate'):
            for kind in (['launch-template'] if action=='CreateLaunchTemplate' else ['instance','volume','network-interface','fleet'] if action=='CreateFleet' else ['instance','volume','network-interface']):
                cases.append((name+'-'+action+'-'+kind, 'ec2:'+action, PREFIX+kind+'/test', ctx,
                              not (action == 'CreateFleet' and kind == 'network-interface')))
                tagged = {**ctx, 'ec2:CreateAction':action}
                cases.append((name+'-tag-'+action+'-'+kind, 'ec2:CreateTags', PREFIX+kind+'/test', tagged, True))
        resource_ctx = tag_context(pool, resource=True)
        for action in ('ec2:CreateFleet','ec2:RunInstances','ec2:DeleteLaunchTemplate'):
            cases.append((name+'-template-'+action, action, PREFIX+'launch-template/lt-00000000000000001', resource_ctx, True))
    for name, mutate in [
        ('wrong-pool', lambda c: c.update({REQ_POOL:'foreign'})),
        ('wrong-class', lambda c: c.update({REQ_CLASS:'foreign'})),
        ('wrong-cluster', lambda c: c.update({'aws:RequestTag/kubernetes.io/cluster/'+CLUSTER:'foreign','aws:RequestTag/eks:eks-cluster-name':'foreign'})),
        ('missing-pool', lambda c: c.pop(REQ_POOL)),
        ('missing-class', lambda c: c.pop(REQ_CLASS)),
    ]:
        for pool in (POOL, ''):
            ctx = tag_context(pool); mutate(ctx)
            for action, kind in [('ec2:CreateLaunchTemplate','launch-template'),('ec2:RunInstances','instance'),('ec2:CreateFleet','fleet'),('ec2:CreateTags','launch-template')]:
                cases.append((name+'-'+repr(pool)+'-'+action, action, PREFIX+kind+'/test', {**ctx,'ec2:CreateAction':'CreateLaunchTemplate'}, False))
    for name, changes in [('wrong-class',{RES_CLASS:'foreign'}),('wrong-pool',{RES_POOL:'foreign'}),
                          ('wrong-cluster',{'aws:ResourceTag/kubernetes.io/cluster/'+CLUSTER:'foreign'})]:
        ctx = {**tag_context('',resource=True), **changes}
        for action in ('ec2:RunInstances','ec2:CreateFleet','ec2:DeleteLaunchTemplate'):
            cases.append((name+'-resource-'+action, action, PREFIX+'launch-template/test', ctx, False))
    cases.extend([
        ('normal-instance-delete','ec2:TerminateInstances',PREFIX+'instance/test',tag_context(resource=True),True),
        ('validation-cannot-terminate-instance','ec2:TerminateInstances',PREFIX+'instance/test',tag_context('',resource=True),False),
        ('foreign-account','ec2:CreateLaunchTemplate',PREFIX.replace(ACCOUNT,'111122223333')+'launch-template/test',tag_context(''),False),
        ('foreign-region','ec2:CreateLaunchTemplate',PREFIX.replace(REGION,'us-east-1')+'launch-template/test',tag_context(''),False),
        ('cannot-retag-existing-template','ec2:CreateTags',PREFIX+'launch-template/test',tag_context(''),False),
        ('pass-only-node','iam:PassRole',f'arn:aws:iam::{ACCOUNT}:role/test',{'iam:PassedToService':'ec2.amazonaws.com'},True),
        ('cannot-pass-other-role','iam:PassRole',f'arn:aws:iam::{ACCOUNT}:role/other',{'iam:PassedToService':'ec2.amazonaws.com'},False),
        ('cannot-pass-to-lambda','iam:PassRole',f'arn:aws:iam::{ACCOUNT}:role/test',{'iam:PassedToService':'lambda.amazonaws.com'},False),
    ])
    for label, arn, expected in [
        ('provided', f'arn:aws:iam::{ACCOUNT}:instance-profile/{CLUSTER}-karpenter', True),
        ('legacy', f'arn:aws:iam::{ACCOUNT}:instance-profile/{CLUSTER}_4432966060878740941', True),
        ('other-cluster', f'arn:aws:iam::{ACCOUNT}:instance-profile/other_4432966060878740941', False),
        ('other-class-hash', f'arn:aws:iam::{ACCOUNT}:instance-profile/{CLUSTER}_1234', False),
        ('other-account', f'arn:aws:iam::111122223333:instance-profile/{CLUSTER}_4432966060878740941', False),
    ]:
        cases.append((label+'-profile-read', 'iam:GetInstanceProfile', arn, {}, expected))
        for action in ('iam:DeleteInstanceProfile', 'iam:RemoveRoleFromInstanceProfile', 'iam:AddRoleToInstanceProfile'):
            cases.append((label+'-'+action, action, arn, {}, False))
    return cases


class IAMContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.policy = source_policy()
        if os.environ.get('KARPENTER_POLICY_JSON'):
            actual = json.loads(Path(os.environ['KARPENTER_POLICY_JSON']).read_text())
            if cls.policy != actual:
                raise AssertionError('Source fixture differs from the actual Terraform mock-rendered policy')
            cls.policy = actual

    def test_request_context_matrix(self):
        for name, action, resource, context, expected in policy_cases():
            with self.subTest(name=name):
                self.assertEqual(expected, allowed(self.policy,action,resource,context))

    def test_unchanged_action_and_star_resource_surface(self):
        expected = {'ec2:RunInstances','ec2:CreateFleet','ec2:CreateLaunchTemplate','ec2:CreateTags',
            'ec2:TerminateInstances','ec2:DeleteLaunchTemplate','eks:DescribeCluster','ssm:GetParameter',
            'pricing:GetProducts','iam:PassRole','iam:ListInstanceProfiles','iam:GetInstanceProfile',
            *['ec2:'+x for x in ('DescribeCapacityReservations','DescribeImages','DescribeInstances','DescribeInstanceStatus',
                'DescribeInstanceTypeOfferings','DescribeInstanceTypes','DescribeLaunchTemplates','DescribePlacementGroups',
                'DescribeSecurityGroups','DescribeSpotPriceHistory','DescribeSubnets')]}
        self.assertEqual(expected,{a for s in self.policy['Statement'] for a in values(s['Action'])})
        self.assertEqual({'AllowRegionalReadActions','AllowPricingReadActions','ListProfilesForGarbageCollector'},
                         {s['Sid'] for s in self.policy['Statement'] if '*' in values(s['Resource'])})
        self.assertLess(len(json.dumps(self.policy,separators=(',',':'))),10240)
        self.assertTrue(all(s['Effect']=='Allow' for s in self.policy['Statement']))

    def test_pinned_dependency_resources_and_validation_cleanup_scope(self):
        statements={s['Sid']:s for s in self.policy['Statement']}
        fixed=statements['AllowScopedEC2InstanceAccessActions']['Resource']
        self.assertEqual(1,sum(':image/' in r for r in fixed))
        self.assertEqual(2,sum(':subnet/' in r for r in fixed))
        self.assertEqual(2,sum(':security-group/' in r for r in fixed))
        cleanup=statements['AllowNodeClassValidationLaunchTemplateDeletion']
        self.assertEqual('ec2:DeleteLaunchTemplate',cleanup['Action'])
        self.assertEqual(PREFIX+'launch-template/*',cleanup['Resource'])


def helm_block(name):
    text='\n'.join((ROOT/'infra/modules/eks'/n).read_text() for n in ('addons.tf','observability.tf','karpenter.tf'))
    match=re.search(r'(?ms)^resource "helm_release" "'+re.escape(name)+r'" \{.*?^\}',text)
    if not match: raise AssertionError('Missing Helm resource '+name)
    return match.group()


class HelmContracts(unittest.TestCase):
    def test_existing_and_new_dependency_gates(self):
        expected={
            'observability':{'aws_eks_node_group.this','aws_eks_addon.coredns','helm_release.aws_lbc'},
            'metrics_server':{'aws_eks_cluster.this','aws_eks_node_group.this','helm_release.aws_lbc'},
            'karpenter':{'helm_release.karpenter_crd','aws_iam_role_policy.karpenter_controller','aws_eks_addon.coredns','helm_release.aws_lbc'},
            'argocd':{'aws_eks_cluster.this','aws_eks_node_group.this','helm_release.aws_lbc'},
            'external_secrets':{'aws_eks_cluster.this','aws_eks_node_group.this','aws_iam_role_policy_attachment.eso_attach','helm_release.aws_lbc'},
        }
        for name,deps in expected.items():
            body=helm_block(name)
            found=set(re.search(r'depends_on\s*=\s*\[([^]]*)\]',body).group(1).replace(',',' ').split())
            self.assertEqual(deps,found,name)
        self.assertRegex(helm_block('aws_lbc'),r'\bwait\s*=\s*true')

    def test_actual_dev_graph_has_no_cycle_and_lbc_edges(self):
        if os.environ.get('KARPENTER_GRAPH'):
            graph=Path(os.environ['KARPENTER_GRAPH']).read_text()
        else:
            p=subprocess.run(['terraform','-chdir='+str(ROOT/'infra/environments/dev'),'graph','-type=plan'],capture_output=True,text=True)
            self.assertEqual(0,p.returncode,'Terraform dependency graph failed')
            graph=p.stdout
        edges=re.findall(r'"([^"\n]+)"\s*->\s*"([^"\n]+)"',graph)
        for name in ('observability','metrics_server','karpenter','argocd','external_secrets'):
            self.assertIn((f'[root] module.eks.helm_release.{name} (expand)',
                           '[root] module.eks.helm_release.aws_lbc (expand)'),edges)
        links={}
        for a,b in edges: links.setdefault(a,[]).append(b)
        active=set();done=set()
        def visit(node):
            self.assertNotIn(node,active,'Dependency cycle')
            if node in done:return
            active.add(node)
            for other in links.get(node,[]):visit(other)
            active.remove(node);done.add(node)
        for node in links:visit(node)


if __name__=='__main__':
    unittest.main()
