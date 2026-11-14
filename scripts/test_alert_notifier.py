import importlib.util,json,os,unittest
from pathlib import Path
from unittest.mock import patch
P=Path(__file__).resolve().parents[1]/'infra/modules/secrets_manager/rotation/slack_notify.py'
spec=importlib.util.spec_from_file_location('notifier',P);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class NotifierTest(unittest.TestCase):
 def notify(self,state):
  with patch.dict(os.environ,{'SLACK_WEBHOOK_URL':'synthetic-not-a-url','SLACK_ALERT_TAGS':'mention'}),patch.object(m,'_post') as post:
   m.handler({'Records':[{'EventSource':'aws:sns','Sns':{'Message':json.dumps({'AlarmName':'db-connections','NewStateValue':state,'NewStateReason':'SYNTHETIC_PRIVATE_REASON'})}}]},None)
   return post.call_args.args
 def test_alarm_and_ok_are_distinct(self):
  a=self.notify('ALARM');b=self.notify('OK');self.assertEqual(a[1],'danger');self.assertEqual(b[1],'good');self.assertIn('ALARM',a[2]);self.assertIn('OK',b[2]);self.assertNotIn('mention',b[3]);self.assertNotIn('PRIVATE',a[3]);self.assertIn('Runbook',a[3]);self.assertIn('UTC',a[3])
 def test_missing_data_not_resolved(self):
  result=self.notify('INSUFFICIENT_DATA');self.assertEqual(result[1],'warning');self.assertIn('warning',result[3])
 def test_rotation_detail_not_echoed(self):
  with patch.dict(os.environ,{'SLACK_WEBHOOK_URL':'synthetic'}),patch.object(m,'_post') as post:
   m.handler({'source':'aws.secretsmanager','detail':{'eventName':'RotationSucceeded','SecretString':'SYNTHETIC_PRIVATE'}},None)
   self.assertEqual(post.call_args.args[1],'good');self.assertNotIn('PRIVATE',post.call_args.args[3])
