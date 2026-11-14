"""Local synthetic tests for U01/U03/U07/U08. No network calls or AWS credentials."""
import copy
import datetime
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

def load(name, filename):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(filename));m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
probe=load('obsprobe','observability-session-probe.py');td=load('storageguard','safe_teardown.py')
NOW=datetime.datetime(2026,10,29,tzinfo=datetime.timezone.utc)
class Reply:
    def __init__(self,status=200,headers=None,body=None):self.status=status;self.headers=headers or {};self.body=body if body is not None else b'{"success":true,"data":{"id":"00000000-0000-4000-8000-000000000001"}}'
    def read(self,*args):return self.body
    def __enter__(self):return self
    def __exit__(self,*args):pass
class Opener:
    def __init__(self,replies):self.replies=iter(replies);self.calls=[]
    def open(self,request,timeout):
        self.calls.append(request)
        reply=next(self.replies)
        if isinstance(reply,Exception):raise reply
        return reply
class ProbeTest(unittest.TestCase):
    def make(self,replies):
        opener=Opener(replies);return probe.Probe('https://example.test','00000000-0000-4000-8000-000000000001','synthetic-access','synthetic-refresh',opener=opener),opener
    def test_read_only_success_no_response_secrets(self):
        p,o=self.make([Reply(body=b'{"success":true,"data":{"id":"00000000-0000-4000-8000-000000000001","name":"PRIVATE_BODY"}}')]);result=p.once();self.assertEqual(result['result'],'success');self.assertNotIn('PRIVATE',json.dumps(result));self.assertEqual(o.calls[0].get_method(),'GET')
    def test_http_200_spa_or_other_profile_is_not_business_success(self):
        for body in [b'<html>SPA fallback</html>', b'{"success":true,"data":{"id":"other-user"}}']:
            p,o=self.make([Reply(body=body)]);self.assertEqual(p.once()['result'],'unexpected_response')
    def test_timeout_not_success_or_zero_rate(self):
        for error in [TimeoutError('PRIVATE_URL'),probe.http.client.IncompleteRead(b'PRIVATE_BODY')]:
            p,o=self.make([error]);result=p.once();self.assertEqual(result['result'],'transport_failure');self.assertNotIn('PRIVATE',json.dumps(result))
    def test_refresh_in_memory_rotated_cookie(self):
        p,o=self.make([Reply(401),Reply(200,{'Set-Cookie':'refreshToken=synthetic-new; HttpOnly'},b'{"success":true,"data":{"accessToken":"synthetic-new-access"}}'),Reply()]);self.assertEqual(p.once()['result'],'success');self.assertEqual(p.refresh,'synthetic-new');self.assertEqual(o.calls[1].full_url,'https://example.test/auth/refresh');self.assertEqual(o.calls[1].get_method(),'POST')
    def test_credential_failure_not_infrastructure_failure(self):
        p,o=self.make([Reply(401),Reply(401)]);self.assertEqual(p.once()['result'],'probe_auth_failed')
    def test_rate_limit_distinct(self):
        p,o=self.make([Reply(429)]);self.assertEqual(p.once()['result'],'rate_limited')
    def test_rejects_destination_injection(self):
        for base in ['http://example.test','https://u:p@example.test','https://example.test?token=secret','https://example.test/path']:
            with self.assertRaises(ValueError):probe.Probe(base,'0'*36,'x')
    def test_observer_down_and_remote_rejected(self):
        self.assertFalse(probe.observer_probe('loki','http://127.0.0.1:1/ready',opener=Opener([TimeoutError()]))['healthy'])
        with self.assertRaises(ValueError):probe.observer_probe('loki','https://remote.test/ready')
    def test_preflight_missing_receiver_rejects(self):
        with self.assertRaises(ValueError):probe.check_preflight({'source_sha':'a'*40})

class ArtifactTest(unittest.TestCase):
    def fixture(self):
        sha='a'*40;rev='d'*40;digests={'was':'sha256:'+'b'*64,'web':'sha256:'+'c'*64}
        data={'source_sha':sha,'gitops_revision':rev,'digests':digests,'observed_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'application':{'metadata':{'name':'food-delivery-dev'},'spec':{'destination':{'namespace':'app'}},'status':{'sync':{'status':'Synced','revision':rev},'health':{'status':'Healthy'},'operationState':{'phase':'Succeeded','syncResult':{'revision':rev,'resources':[{'kind':'Job','name':'was-db-migration','namespace':'app','hookPhase':'Succeeded'}]}}}},'pods':{'items':[]}}
        for role in ['was','web']:
            for index in range(2):
                data['pods']['items'].append({'metadata':{'name':role+'-'+str(index),'uid':role+'-uid-'+str(index),'namespace':'app','labels':{'app':role}},'spec':{'containers':[{'name':role,'image':'registry.test/'+role+':'+sha}]},'status':{'phase':'Running','conditions':[{'type':'Ready','status':'True'}],'containerStatuses':[{'name':role,'ready':True,'state':{'running':{}},'imageID':'docker-pullable://registry.test/'+role+'@'+digests[role]}]}})
        return data
    def test_source_and_gitops_differ_but_same_source_images_are_valid_snapshots(self):
        result=probe.check_artifacts(self.fixture());self.assertFalse(result['live_verified']);self.assertEqual(result['ready_role_counts'],{'was':2,'web':2})
    def test_bad_digest_missing_hook_unready_stale_or_wrong_revision_rejected(self):
        for case in ['digest','hook','ready','stale','revision','duplicate']:
            data=self.fixture()
            if case=='digest':data['pods']['items'][0]['status']['containerStatuses'][0]['imageID']='containerd://sha256:'+'f'*64
            elif case=='hook':data['application']['status']['operationState']['syncResult']['resources']=[]
            elif case=='ready':data['pods']['items'][0]['status']['conditions'][0]['status']='False'
            elif case=='stale':data['observed_at']='2020-01-01T00:00:00Z'
            elif case=='duplicate':data['pods']['items'][1]=copy.deepcopy(data['pods']['items'][0])
            else:data['application']['status']['sync']['revision']='f'*40
            with self.assertRaises(ValueError):probe.check_artifacts(data)

class StorageTest(unittest.TestCase):
    def setUp(self):
        self.row={'pv':'pvc-test','pvc':'storage-loki-0','pvc_uid':'claim-uid','volume_id':'vol-0123456789abcdef0','az':'ap-northeast-2a','instance_ids':['i-test'],'owner':'operator','retain_until':'2026-10-30T00:00:00Z'}
        self.m={'account':td.ACCOUNT,'region':td.REGION,'project':'food-delivery','environment':'dev','cluster':'test','bucket':{'name':'food-delivery-loki-test','owner':'operator','retain_until':'2026-11-01T00:00:00Z'},'volumes':[self.row]}
        self.pv={'metadata':{'name':'pvc-test'},'spec':{'storageClassName':'logging-gp3','persistentVolumeReclaimPolicy':'Retain','claimRef':{'namespace':'monitoring','name':'storage-loki-0','uid':'claim-uid'},'csi':{'driver':'ebs.csi.aws.com','volumeHandle':self.row['volume_id']},'nodeAffinity':{'required':{'nodeSelectorTerms':[{'matchExpressions':[{'key':'topology.ebs.csi.aws.com/zone','operator':'In','values':['ap-northeast-2a']}]}]}}}}
        tags={'Project':'food-delivery','Environment':'dev','Cluster':'test','Purpose':'loki-wal','ebs.csi.aws.com/cluster':'true','kubernetes.io/created-for/pvc/namespace':'monitoring','kubernetes.io/created-for/pvc/name':'storage-loki-0','kubernetes.io/created-for/pv/name':'pvc-test'}
        self.volume={'VolumeId':self.row['volume_id'],'AvailabilityZone':self.row['az'],'Tags':[{'Key':k,'Value':v} for k,v in tags.items()],'Attachments':[{'InstanceId':'i-test'}]}
    def check(self):return td.validate_manifest(self.m,[self.pv],[self.volume],account=td.ACCOUNT,region=td.REGION,cluster='test',now=NOW)
    def test_exact_owner_pass_does_not_authorize_delete(self):self.assertFalse(self.check()['deletion_authorized'])
    def test_foreign_context_rejected(self):
        for key in ['account','region','cluster','environment']:
            orig=self.m[key];self.m[key]='other'
            with self.assertRaises(td.StorageOwnershipError):self.check()
            self.m[key]=orig
    def test_missing_volume_tag_rejected(self):
        self.volume['Tags']=self.volume['Tags'][1:]
        with self.assertRaises(td.StorageOwnershipError):self.check()
    def test_claim_uid_drift_rejected(self):
        self.pv['spec']['claimRef']['uid']='other'
        with self.assertRaises(td.StorageOwnershipError):self.check()
    def test_attachment_drift_rejected(self):
        self.volume['Attachments']=[]
        with self.assertRaises(td.StorageOwnershipError):self.check()
    def test_az_affinity_drift_rejected(self):
        self.pv['spec']['nodeAffinity']['required']['nodeSelectorTerms'][0]['matchExpressions'][0]['values']=['ap-northeast-2b']
        with self.assertRaises(td.StorageOwnershipError):self.check()
    def test_expired_or_unapproved_retention_rejected(self):
        self.m['bucket']['retain_until']='2026-10-01T00:00:00Z'
        with self.assertRaises(td.StorageOwnershipError):self.check()
    def test_archive_policy_json_not_helm_yaml(self):
        policy=json.dumps({'Statement':[{'Resource':'arn:aws:s3:::food-delivery-loki-test'},{'Resource':'arn:aws:s3:::food-delivery-loki-test/*'}]})
        self.assertEqual(td.logging_bucket_from_policies([policy]),'food-delivery-loki-test')
        with self.assertRaises(td.UnsafeTeardown):td.logging_bucket_from_policies([policy,policy])
    def test_runtime_inventory_uses_expected_archive_owner_and_existing_persistent_tags(self):
        self.m['bucket']['retain_until']=(datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=1)).isoformat()
        self.row['retain_until']=self.m['bucket']['retain_until']
        outer=self
        class Runner:
            def kube(self,*args,**kwargs):return {'items':[outer.pv]}
            def aws(self,service,op,*args):
                if service=='ec2':return {'Volumes':[outer.volume]}
                outer.assertIn('--expected-bucket-owner',args)
                if op=='get-bucket-location':return {'LocationConstraint':td.REGION}
                return {'TagSet':[{'Key':'Project','Value':'food-delivery'},{'Key':'Purpose','Value':'retained-loki-logs'}]}
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'retention.json';path.write_text(json.dumps(self.m))
            result=td.logging_storage_inventory(Runner(),'context','test','food-delivery-loki-test',{'LOGGING_RETENTION_MANIFEST':str(path)})
            self.assertFalse(result['deletion_authorized'])
    def test_duplicate_volume_rejected(self):
        self.m['volumes'].append(copy.deepcopy(self.row))
        with self.assertRaises(td.StorageOwnershipError):self.check()
    def test_delete_policy_rejected(self):
        self.pv['spec']['persistentVolumeReclaimPolicy']='Delete'
        with self.assertRaises(td.StorageOwnershipError):self.check()

if __name__=='__main__':unittest.main()
