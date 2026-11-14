"""Local contracts and mocked kubectl only; no AWS, Terraform or notification calls."""
import base64
import contextlib
import copy
import datetime
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
import hcl2
import yaml
import r2_target as target
import provision_logging_alert_secret as secret

ROOT = Path(__file__).resolve().parents[1]


def synthetic_hook():
    # Constructed synthetic fixture only, never a real endpoint or request.
    return 'https://' + 'hooks.slack.com' + '/services/' + '/'.join(['SYNTHETIC_A', 'SYNTHETIC_B', 'SYNTHETIC_C'])


def example_target():
    # The real target is private and git-ignored; tests use the committed fake example.
    with tempfile.TemporaryDirectory() as d:
        p = Path(d);(p/'config').mkdir()
        (p/'config/r2-dev-target.json').write_text((ROOT/'config/r2-dev-target.example.json').read_text())
        return target.load_target(p)


class R2TargetTests(unittest.TestCase):
    def setUp(self):
        self.t = example_target()

    def changed_target(self, change):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d);(p/'config').mkdir()
            t = copy.deepcopy(self.t);change(t)
            (p/'config/r2-dev-target.json').write_text(json.dumps(t))
            return target.load_target(p)

    def test_generated_files_match_and_no_runtime_values(self):
        for text in target.generated_files(self.t).values():
            self.assertNotIn(synthetic_hook(), text)
            self.assertNotIn('karpenter_ami_id', text)
            self.assertNotIn('slack_webhook_url', text)

    def test_dev_archive_and_backend_contract(self):
        files = target.generated_files(self.t)
        dev = json.loads(files['infra/environments/dev/r2-target.tfvars.json'])
        archive = json.loads(files['infra/logging-archive/r2-target.tfvars.json'])
        backend = hcl2.loads(files['infra/logging-archive/backend.r2.hcl'])
        self.assertEqual(dev['loki_bucket_name'], archive['bucket_name'])
        self.assertEqual(archive['allowed_account_id'], '123456789012')
        self.assertNotEqual(backend['key'], target.DEV_STATE_KEY)
        self.assertTrue(backend['use_lockfile'])
        self.assertNotIn(archive['bucket_name'], target.protected_buckets(self.t))
        self.assertEqual(dev['allowed_account_ids'], [self.t['account_id']])
        self.assertEqual(dev['terraform_state_bucket_name'], backend['bucket'])

    def test_all_protected_buckets_rejected(self):
        for bucket in target.protected_buckets(self.t):
            with self.subTest(bucket=bucket), self.assertRaises(target.InputError):
                self.changed_target(lambda t: t.update(archive_bucket=bucket))

    def test_bad_archive_names_rejected(self):
        for value in ['', 'food-delivery-loki-bad/', 'food-delivery-loki-UPPER', 'food-delivery-loki-'+'a'*60]:
            with self.subTest(value=value), self.assertRaises(target.InputError):
                self.changed_target(lambda t: t.update(archive_bucket=value))

    def test_dev_state_reuse_rejected(self):
        with self.assertRaises(target.InputError):
            self.changed_target(lambda t: t['archive_backend'].update(key=target.DEV_STATE_KEY))

    def test_foreign_account_and_region_rejected(self):
        for key, value in [('account_id', '000000000000'), ('account_id', 'not-an-id'), ('region', 'ap-northeast-1'), ('workspace', 'prod')]:
            with self.subTest(key=key), self.assertRaises(target.InputError):
                self.changed_target(lambda t: t.update({key:value}))

    def test_static_runtime_inputs_rejected(self):
        for key in ['slack_webhook_url', 'karpenter_ami_id', 'karpenter_ami_verified']:
            with self.subTest(key=key), self.assertRaises(target.InputError):
                self.changed_target(lambda t: t['dev_variables'].update({key:'synthetic'}))

    def test_unreviewed_values_never_enter_generated_files(self):
        for section,key in [('dev_variables','unreviewed_value'),('archive_backend','access_key')]:
            with self.subTest(section=section), self.assertRaises(target.InputError):
                self.changed_target(lambda t:t[section].update({key:'synthetic-not-a-secret'}))

    def test_invalid_nested_types_fail_closed(self):
        for section in ['dev_variables','archive_backend']:
            with self.subTest(section=section),self.assertRaises(target.InputError):
                self.changed_target(lambda t:t.update({section:[]}))

    def test_target_flags_cannot_silently_drift(self):
        for key, value in [('enable_central_logging',False), ('mng_instance_type','t3.medium'),
                           ('mng_max_size',4), ('waf_count_mode',False), ('enable_ops_monitoring',False)]:
            with self.subTest(key=key), self.assertRaises(target.InputError):
                self.changed_target(lambda t: t['dev_variables'].update({key:value}))

    def test_identity_values_must_stay_consistent(self):
        for change in [lambda t: t['dev_variables'].update(allowed_account_ids=['000000000000']),
                       lambda t: t['dev_variables'].update(terraform_state_bucket_name='other-bucket'),
                       lambda t: t['dev_variables'].update(dev_domain_name='dev.unrelated.test'),
                       lambda t: t['dev_variables'].update(route53_zone_name='Not A Domain'),
                       lambda t: t['dev_variables']['was_aws_access']['s3'].update(bucket_name=t['archive_backend']['bucket'])]:
            with self.subTest(), self.assertRaises(target.InputError):
                self.changed_target(change)

    def test_ses_permissions_not_added(self):
        with self.assertRaises(target.InputError):
            self.changed_target(lambda t: t['dev_variables']['was_aws_access'].update(ses={}))

    def test_generated_drift_is_detected_and_repaired_nonsecret_only(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            self.assertEqual(len(target.sync_files(p,self.t)),3)
            target.sync_files(p,self.t,True)
            self.assertEqual(target.sync_files(p,self.t),[])
            f=p/'infra/environments/dev/r2-target.tfvars.json';f.write_text('{}')
            self.assertEqual(target.sync_files(p,self.t),['infra/environments/dev/r2-target.tfvars.json'])

    def test_mng_cap_wired_and_default_preserved(self):
        with (ROOT/'infra/environments/dev/main.tf').open() as f:main=hcl2.load(f)
        eks=next(m['eks'] for m in main['module'] if 'eks' in m)
        self.assertEqual(eks['desired_size'],2);self.assertEqual(eks['min_size'],2)
        self.assertEqual(eks['max_size'],'${var.mng_max_size}')
        with (ROOT/'infra/environments/dev/variables.tf').open() as f:v=hcl2.load(f)
        cap=next(x['mng_max_size'] for x in v['variable'] if 'mng_max_size' in x)
        self.assertEqual(cap['default'],4)
        self.assertEqual(self.t['dev_variables']['mng_max_size'],2)

    def test_archive_destroy_and_retention_still_protected(self):
        with (ROOT/'infra/logging-archive/main.tf').open() as f:c=hcl2.load(f)
        bucket=next(x['aws_s3_bucket']['logs'] for x in c['resource'] if 'aws_s3_bucket' in x)
        self.assertFalse(bucket['force_destroy']);self.assertTrue(bucket['lifecycle'][0]['prevent_destroy'])
        self.assertFalse(any('aws_s3_bucket_lifecycle_configuration' in x for x in c['resource']))
        loki=yaml.safe_load((ROOT/'infra/modules/eks/logging/loki-values.yaml').read_text())
        self.assertEqual(loki['loki']['limits_config']['retention_period'],'168h')
        self.assertTrue(loki['loki']['compactor']['retention_enabled'])
        self.assertTrue(loki['loki']['ingester']['wal']['enabled'])
        self.assertFalse(loki['singleBinary']['persistence']['enableStatefulSetAutoDeletePVC'])

    def test_karpenter_dynamic_limits_and_verified_pinned_ami(self):
        # Template text is not YAML until rendered; assert the fixed existing contract.
        s=(ROOT/'infra/modules/eks/karpenter-config/templates/capacity.yaml').read_text()
        self.assertIn('cpu: "4"',s);self.assertIn('memory: 8Gi',s)
        self.assertIn('values: [on-demand]',s);self.assertIn('values: [medium, large]',s)
        self.assertIn('required "A verified fixed EKS 1.36 AL2023 AMI ID is required"',s)
        self.assertNotIn('nodes:',s.split('  limits:',1)[1].split('  disruption:',1)[0])

    def test_secret_precondition_is_separate_from_app_argocd(self):
        values=yaml.safe_load((ROOT/'infra/modules/eks/logging/alerting-values.yaml').read_text())
        a=values['alertmanager'];self.assertEqual(a['alertmanagerSpec']['secrets'],['logging-alerts'])
        # The default route sends to "slack"; a "null" receiver exists only for silenced routes.
        receivers={r['name']:r for r in a['config']['receivers']}
        self.assertEqual(a['config']['route']['receiver'],'slack')
        slack=receivers['slack']['slack_configs'][0]
        self.assertEqual(slack['api_url_file'],'/etc/alertmanager/secrets/logging-alerts/slack-webhook')
        self.assertTrue(slack['send_resolved'])
        self.assertNotIn('slack_configs',receivers.get('null',{}))
        k=yaml.safe_load((ROOT/'k8s/overlays/dev/kustomization.yaml').read_text())
        self.assertNotIn('observability-prerequisites',' '.join(k['resources']))
        n=yaml.safe_load((ROOT/'k8s/observability-prerequisites/namespace.yaml').read_text())
        self.assertEqual(n['metadata']['name'],'monitoring')
        self.assertEqual(n['metadata']['labels']['food-delivery/environment'],'dev')

    def test_actual_ses_dev_remains_no_send(self):
        s=(ROOT/'k8s/overlays/dev/was-irsa-patch.yaml').read_text()
        self.assertIn('SKIP_EMAIL_NOTIFICATION: "true"',s)
        self.assertIn('AWS_SES_SENDER_EMAIL: ""',s)


class RuntimeReceiptTests(unittest.TestCase):
    def setUp(self):
        self.t=example_target()
        self.now=datetime.datetime(2026,10,31,tzinfo=datetime.timezone.utc)
        self.ami='ami-'+'0'*16+'1'  # SYNTHETIC, never written to target configuration.
        self.env={'AWS_PROFILE':'my-profile','AWS_REGION':'ap-northeast-2','TF_WORKSPACE':'default',
                  'TF_VAR_karpenter_ami_id':self.ami,'TF_VAR_karpenter_ami_verified':'true',
                  'TF_VAR_slack_webhook_url':synthetic_hook()}
        self.receipt={'account_id':'123456789012','region':'ap-northeast-2','owner_id':'602401143452',
                      'image_id':self.ami,'state':'available','architecture':'x86_64',
                      'name':'amazon-eks-node-al2023-x86_64-standard-1.36-v20261030',
                      'observed_at':'2026-10-31T00:00:00Z','approved_for_use':True}

    def check(self,env=None,receipt=None):
        return target.check_runtime(self.t,self.env if env is None else env,
                                    self.receipt if receipt is None else receipt,self.now)

    def test_valid_synthetic_contract_does_not_claim_live_verification(self):
        r=self.check();self.assertTrue(r['runtime_input_contract_valid'])
        self.assertFalse(r['AWS_verified_by_this_script']);self.assertEqual(r['AWS_deployment'],'NO-GO')
        self.assertNotIn(synthetic_hook(),json.dumps(r));self.assertNotIn(self.ami,json.dumps(r))

    def test_absent_inputs_block(self):
        r=self.check(env={},receipt={})
        self.assertFalse(r['runtime_input_contract_valid'])
        self.assertIn('AMI_ID_REQUIRED',r['errors']);self.assertIn('PRIVATE_WEBHOOK_REQUIRED',r['errors'])

    def test_stale_or_naive_or_future_receipts_block(self):
        for stamp in ['2026-10-20T00:00:00Z','2026-10-31T00:00:00','2026-11-01T00:00:00Z','private-invalid']:
            with self.subTest(stamp=stamp):
                r=dict(self.receipt,observed_at=stamp)
                self.assertFalse(self.check(receipt=r)['runtime_input_contract_valid'])

    def test_wrong_ami_scope_state_version_owner_block(self):
        for key,value in [('owner_id','000000000000'),('region','ap-northeast-1'),
                          ('architecture','arm64'),('state','pending'),('approved_for_use',False),
                          ('name','amazon-eks-node-al2023-x86_64-standard-1.35-v20261030')]:
            with self.subTest(key=key):
                self.assertFalse(self.check(receipt=dict(self.receipt,**{key:value}))['runtime_input_contract_valid'])

    def test_unsafe_environment_overrides_block(self):
        for key in ['TF_CLI_ARGS','TF_VAR_owner','AWS_ACCESS_KEY_ID','AWS_ENDPOINT_URL','AWS_ENDPOINT_URL_EC2']:
            with self.subTest(key=key):
                r=self.check(env=dict(self.env,**{key:'synthetic'}))
                self.assertIn('UNREVIEWED_ENVIRONMENT_OVERRIDE',r['errors'])

    def test_webhook_url_confusion_rejected_without_echo(self):
        good=synthetic_hook()
        invalid=['',good+'?secret=x',good+'#x',good+'\n',good.replace('hooks.slack.com','hooks.slack.com.evil.test'),
                 good.replace('https://','http://'),good.replace('https://','https://user@'),
                 good.replace('/services/','/services/%2f')]
        for hook in invalid:
            with self.subTest(case=invalid.index(hook)):
                self.assertFalse(target.valid_webhook(hook))
                result=self.check(env=dict(self.env,TF_VAR_slack_webhook_url=hook))
                self.assertIn('PRIVATE_WEBHOOK_REQUIRED',result['errors'])


class SecretSupplierTests(unittest.TestCase):
    def setUp(self):
        self.t=example_target()
        self.context='arn:aws:eks:ap-northeast-2:123456789012:cluster/cluster'
        self.ns={'metadata':{'name':'monitoring','labels':{'app.kubernetes.io/part-of':'food-delivery',
                                                         'food-delivery/environment':'dev'}}}

    def runner(self,code=0,ns=None):
        return Mock(side_effect=[Mock(returncode=0,stdout=json.dumps(self.ns if ns is None else ns)),
                                 Mock(returncode=code,stdout='',stderr='SYNTHETIC_PRIVATE_FAILURE')])

    def test_secret_object_is_exact_and_in_memory_only(self):
        o=secret.secret_object(synthetic_hook())
        self.assertEqual(o['metadata']['namespace'],'monitoring');self.assertEqual(o['metadata']['name'],'logging-alerts')
        self.assertEqual(set(o['data']),{'slack-webhook'})
        self.assertEqual(base64.b64decode(o['data']['slack-webhook']).decode(),synthetic_hook())

    def test_mocked_create_only_no_webhook_in_argv_or_result(self):
        run=self.runner()
        with patch.dict(os.environ,{'TF_VAR_slack_webhook_url':synthetic_hook()}):
            r=secret.create_secret(self.t,self.context,synthetic_hook(),True,run=run)
        self.assertTrue(r['secret_created']);self.assertFalse(r['notification_sent'])
        self.assertEqual(run.call_count,2)
        args,kwargs=run.call_args_list[1]
        self.assertEqual(args[0][-3:],['create','-f','-'])
        self.assertNotIn(synthetic_hook(),json.dumps(args));self.assertNotIn(synthetic_hook(),json.dumps(r))
        self.assertEqual(json.loads(kwargs['input'])['kind'],'Secret')
        self.assertNotIn('TF_VAR_slack_webhook_url',kwargs['env'])

    def test_wrong_context_or_missing_approval_never_calls_kubectl(self):
        for context,reviewed in [('default',True),(self.context,False)]:
            run=Mock()
            with self.assertRaises(target.InputError):secret.create_secret(self.t,context,synthetic_hook(),reviewed,run)
            run.assert_not_called()

    def test_wrong_namespace_owner_never_creates_secret(self):
        run=self.runner(ns={'metadata':{'name':'monitoring','labels':{}}})
        with self.assertRaises(target.InputError):secret.create_secret(self.t,self.context,synthetic_hook(),True,run)
        self.assertEqual(run.call_count,1)

    def test_existing_secret_or_error_no_overwrite_fallback(self):
        run=self.runner(code=1)
        with self.assertRaisesRegex(target.InputError,'SECRET_CREATE_FAILED_NO_OVERWRITE_ATTEMPTED'):
            secret.create_secret(self.t,self.context,synthetic_hook(),True,run)
        self.assertEqual(run.call_count,2)
        for call in run.call_args_list:
            self.assertNotIn('apply',call.args[0]);self.assertNotIn('replace',call.args[0]);self.assertNotIn('delete',call.args[0])

    def test_default_cli_check_never_calls_subprocess_or_echoes(self):
        buf=io.StringIO()
        with patch.dict(os.environ,{'TF_VAR_slack_webhook_url':synthetic_hook()},clear=True), \
             patch.object(sys,'argv',['secret-supplier']),patch.object(secret.subprocess,'run') as run, \
             patch.object(secret,'load_target',lambda *a, **k: example_target()), \
             contextlib.redirect_stdout(buf):
            self.assertEqual(secret.main(),0)
        run.assert_not_called();self.assertNotIn(synthetic_hook(),buf.getvalue())


import sys
if __name__ == '__main__':
    unittest.main()
