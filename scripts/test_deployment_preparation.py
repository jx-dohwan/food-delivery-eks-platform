"""Local preparation contracts; no AWS, deployment, Git publication or email."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


def render(environment):
    text = subprocess.check_output([os.environ['KUSTOMIZE_BIN'], 'build',
                                    str(ROOT / 'k8s/overlays' / environment)], text=True)
    return json.loads(subprocess.check_output(['ruby', '-ryaml', '-rjson', '-e',
        'puts JSON.generate(YAML.load_stream(STDIN.read).compact)'], input=text, text=True))


class DeploymentPreparationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dev = render('dev')
        cls.preview = render('preflight-no-email')

    def config(self, documents):
        return next(d['data'] for d in documents if d['kind'] == 'ConfigMap'
                    and d['metadata']['name'] == 'was-config')

    def test_no_email_preview_overrides_sender_and_skip(self):
        self.assertEqual('true', self.config(self.dev)['SKIP_EMAIL_NOTIFICATION'])
        self.assertEqual('', self.config(self.dev)['AWS_SES_SENDER_EMAIL'])
        self.assertEqual('true', self.config(self.preview)['SKIP_EMAIL_NOTIFICATION'])
        self.assertEqual('', self.config(self.preview)['AWS_SES_SENDER_EMAIL'])
        for d in self.preview:
            if d['kind'] == 'Deployment' and d['metadata']['name'] == 'was-deployment':
                env = d['spec']['template']['spec']['containers'][0].get('env', [])
                self.assertFalse(any(e['name'] in {'SKIP_EMAIL_NOTIFICATION', 'AWS_SES_SENDER_EMAIL'} for e in env))

    def test_preview_changes_only_two_email_configuration_values(self):
        # The preview must preserve all other application, logging and security settings.
        import copy
        expected = copy.deepcopy(self.dev)
        for d in expected:
            if d['kind'] == 'ConfigMap' and d['metadata']['name'] == 'was-config':
                d['data'].update(SKIP_EMAIL_NOTIFICATION='true', AWS_SES_SENDER_EMAIL='')
        key = lambda d: (d['kind'], d['metadata'].get('namespace', ''), d['metadata']['name'])
        self.assertEqual(sorted(expected, key=key), sorted(self.preview, key=key))

    def test_argocd_target_is_not_silently_changed(self):
        text = (ROOT / 'argocd-app.yaml').read_text()
        self.assertIn('path: k8s/overlays/dev', text)
        self.assertNotIn('preflight-no-email', text)

    def test_old_image_source_is_still_rejected_by_real_gate(self):
        spec = importlib.util.spec_from_file_location('deployment_gate', ROOT / 'scripts/pre-full-deploy.py')
        gate = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gate)
        with self.assertRaisesRegex(ValueError, 'Image source differs'):
            gate.validate_image_source(self.dev, 'dev', ROOT)

    def test_docker_contexts_and_latest_guard_implementation_are_present(self):
        workflow = (ROOT / '.github/workflows/deploy.yml').read_text()
        for component in ('coupang_eats_backend_v2', 'coupang_eats_frontend_v2'):
            self.assertIn('context: ./app/' + component, workflow)
            self.assertTrue((ROOT / 'app' / component / 'Dockerfile').is_file())
        self.assertIn('not is_project_repository(source.get("repoURL"))',
                      (ROOT / 'scripts/safe_teardown.py').read_text())

    def test_provider_lockfiles_are_publishable_without_force_add(self):
        paths = ['infra/bootstrap/.terraform.lock.hcl',
                 'infra/environments/dev/.terraform.lock.hcl',
                 'infra/logging-archive/.terraform.lock.hcl',
                 'infra/modules/eks/.terraform.lock.hcl']
        result = subprocess.run(['git', '-C', str(ROOT), 'check-ignore', '--no-index', '--stdin'],
                                input='\n'.join(paths)+'\n', capture_output=True, text=True)
        self.assertEqual(1, result.returncode)
        self.assertEqual('', result.stdout)


if __name__ == '__main__':
    unittest.main()
