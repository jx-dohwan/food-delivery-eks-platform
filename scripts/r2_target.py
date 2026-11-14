#!/usr/bin/env python3
"""Prepare/check NONSECRET R2 inputs. No AWS, Terraform or network execution."""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import sys
import urllib.parse

ROOT = Path(__file__).resolve().parents[1]
ACCOUNT_RE = r'[0-9]{12}'
DOMAIN_RE = r'(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}'
BUCKET_RE = r'[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]'
DEV_STATE_KEY = 'terraform/dev/terraform.tfstate'


class InputError(ValueError):
    """Only a fixed safe code, never user input or underlying exception text."""


def protected_buckets(target):
    """Buckets no generated input may reuse: state, account trail and the app upload bucket.
    Derived from the private target itself, so no account-specific value lives in Git."""
    upload = ((target.get('dev_variables') or {}).get('was_aws_access') or {}).get('s3') or {}
    return {
        (target.get('archive_backend') or {}).get('bucket', ''),
        f"food-delivery-cloudtrail-{target.get('account_id', '')}-{target.get('region', '')}",
        upload.get('bucket_name', ''),
    } - {''}


def load_target(root=ROOT):
    """Read the git-ignored private target (copy config/r2-dev-target.example.json to start)."""
    try:
        data = json.loads((root / 'config/r2-dev-target.json').read_text())
    except (OSError, ValueError):
        raise InputError('TARGET_UNREADABLE') from None
    if not isinstance(data, dict):
        raise InputError('TARGET_UNREADABLE')
    if (data.get('schema_version') != 1 or not re.fullmatch(ACCOUNT_RE, str(data.get('account_id', '')))
            or data.get('profile') != 'my-profile' or data.get('region') != 'ap-northeast-2'
            or data.get('workspace') != 'default' or data.get('cluster_name') != 'cluster'):
        raise InputError('TARGET_SCOPE_MISMATCH')
    bucket = data.get('archive_bucket', '')
    if (bucket in protected_buckets(data) or not re.fullmatch(r'food-delivery-loki-[a-z0-9-]{1,40}', bucket)
            or len(bucket) > 63 or bucket.endswith('-')):
        raise InputError('ARCHIVE_NAME_INVALID')
    backend = data.get('archive_backend', {})
    if not isinstance(backend, dict) or set(backend) != {
            'bucket', 'key', 'region', 'profile', 'encrypt', 'use_lockfile', 'allowed_account_ids'}:
        raise InputError('ARCHIVE_BACKEND_INVALID')
    if (not re.fullmatch(BUCKET_RE, str(backend.get('bucket', '')))
            or backend.get('key') != 'terraform/logging-archive/dev/terraform.tfstate'
            or backend.get('key') == DEV_STATE_KEY or backend.get('region') != data['region']
            or backend.get('profile') != data['profile'] or backend.get('encrypt') is not True
            or backend.get('use_lockfile') is not True
            or backend.get('allowed_account_ids') != [data['account_id']]):
        raise InputError('ARCHIVE_BACKEND_INVALID')
    v = data.get('dev_variables', {})
    if not isinstance(v, dict):
        raise InputError('TARGET_FLAGS_CHANGED')
    if any(x in v for x in ['slack_webhook_url', 'karpenter_ami_id', 'karpenter_ami_verified']):
        raise InputError('RUNTIME_INPUT_IN_STATIC_PROFILE')
    expected = {'region': data['region'], 'owner': '', 'project_name': 'food-delivery',
                'environment': 'dev', 'enable_oss_observability': True,
                'enable_central_logging': True, 'mng_instance_type': 't3.large',
                'mng_max_size': 2, 'enable_karpenter': True, 'enable_waf': True,
                'waf_count_mode': True, 'waf_rate_limit': 6000, 'enable_ops_monitoring': True,
                'enable_secret_rotation': True,
                'activate_secret_rotation': False, 'manage_ingress_alb_alias': False,
                'manage_www_record': False, 'metrics_server_kubelet_tls_verified': False,
                'enable_sg_auto_remediation': False, 'alb_target_group_arn_suffix': '',
                'allowed_account_ids': [data['account_id']],
                'terraform_state_bucket_name': backend['bucket']}
    identity = {'route53_zone_name', 'dev_domain_name', 'www_domain_name'}
    if set(v) != set(expected) | {'was_aws_access'} | identity:
        raise InputError('UNREVIEWED_STATIC_VARIABLE')
    if any(type(v.get(k)) is not type(value) or v.get(k) != value for k, value in expected.items()):
        raise InputError('TARGET_FLAGS_CHANGED')
    zone = v.get('route53_zone_name')
    if (not isinstance(zone, str) or not re.fullmatch(DOMAIN_RE, zone)
            or any(not isinstance(v.get(k), str) or not v[k].endswith('.' + zone)
                   or not re.fullmatch(DOMAIN_RE, v[k]) for k in ('dev_domain_name', 'www_domain_name'))):
        raise InputError('DOMAIN_INVALID')
    access = v.get('was_aws_access')
    upload = access.get('s3') if isinstance(access, dict) and set(access) == {'s3'} else None
    if (not isinstance(upload, dict) or set(upload) != {'bucket_name', 'encryption'}
            or upload.get('encryption') != 'AES256'
            or not re.fullmatch(BUCKET_RE, str(upload.get('bucket_name', '')))
            or upload['bucket_name'] in {backend['bucket'], f"food-delivery-cloudtrail-{data['account_id']}-{data['region']}"}):
        raise InputError('APPLICATION_BUCKET_OR_SES_CHANGED')
    if data.get('alertmanager') != {
            'namespace': 'monitoring', 'secret_name': 'logging-alerts', 'secret_key': 'slack-webhook',
            'supplier': 'operator-create-only-from-environment',
            'supply_before': 'helm_release.observability', 'app_argocd_manages_secret': False}:
        raise InputError('ALERT_SECRET_CONTRACT_CHANGED')
    return data


def generated_files(target):
    def js(value):
        return json.dumps(value, indent=2, ensure_ascii=False) + '\n'
    dev = dict(target['dev_variables'], loki_bucket_name=target['archive_bucket'])
    archive = {'bucket_name': target['archive_bucket'], 'region': target['region'],
               'allowed_account_id': target['account_id']}
    backend = '# PROPOSED separate archive backend. No Init/State access approved.\n'
    width = max(map(len, target['archive_backend']))
    for key, value in target['archive_backend'].items():
        backend += f'{key:<{width}} = {json.dumps(value)}\n'
    return {'infra/environments/dev/r2-target.tfvars.json': js(dev),
            'infra/logging-archive/r2-target.tfvars.json': js(archive),
            'infra/logging-archive/backend.r2.hcl': backend}


def sync_files(root, target, write=False):
    different = []
    for rel, content in generated_files(target).items():
        f = root / rel
        if not f.is_file() or f.read_text() != content:
            different.append(rel)
            if write:
                f.parent.mkdir(parents=True, exist_ok=True)
                f.write_text(content)
    return different


def valid_webhook(value):
    # Never echo parsed URLs, secrets, validation details or library exceptions.
    if not isinstance(value, str) or len(value) > 1024 or any(c.isspace() for c in value):
        return False
    try:
        u = urllib.parse.urlsplit(value)
        return (u.scheme == 'https' and u.netloc == 'hooks.slack.com'
                and not u.query and not u.fragment and not u.username and not u.password
                and re.fullmatch(r'/services/[A-Za-z0-9_-]{1,128}/[A-Za-z0-9_-]{1,128}/[A-Za-z0-9_-]{1,128}', u.path) is not None)
    except (ValueError, TypeError):
        return False


def check_runtime(target, env, receipt=None, now=None):
    """Validate declarations only; a supplied AMI receipt is NOT live proof."""
    errors = []
    if (env.get('AWS_PROFILE') != target['profile'] or env.get('AWS_REGION') != target['region']
            or env.get('TF_WORKSPACE') != 'default'):
        errors.append('RUNTIME_SCOPE_REQUIRED')
    permitted = {'TF_VAR_karpenter_ami_id', 'TF_VAR_karpenter_ami_verified', 'TF_VAR_slack_webhook_url'}
    if any((k.startswith('TF_VAR_') and k not in permitted) or k.startswith('TF_CLI_ARGS')
           or k.startswith('AWS_ENDPOINT_URL')
           or k in {'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN'}
           for k in env):
        errors.append('UNREVIEWED_ENVIRONMENT_OVERRIDE')
    ami = env.get('TF_VAR_karpenter_ami_id', '')
    if not re.fullmatch(r'ami-[0-9a-f]{17}', ami):
        errors.append('AMI_ID_REQUIRED')
    if env.get('TF_VAR_karpenter_ami_verified') != 'true':
        errors.append('AMI_VERIFICATION_REQUIRED')
    if not valid_webhook(env.get('TF_VAR_slack_webhook_url', '')):
        errors.append('PRIVATE_WEBHOOK_REQUIRED')
    try:
        r = receipt or {}
        observed = datetime.datetime.fromisoformat(r.get('observed_at', '').replace('Z', '+00:00'))
        current = now or datetime.datetime.now(datetime.timezone.utc)
        fresh = observed.tzinfo is not None and 0 <= (current - observed).total_seconds() <= 86400
        if not (r.get('account_id') == target['account_id'] and r.get('region') == target['region']
                and r.get('owner_id') == '602401143452' and r.get('image_id') == ami
                and r.get('state') == 'available' and r.get('architecture') == 'x86_64'
                and re.fullmatch(r'amazon-eks-node-al2023-x86_64-standard-1\.36-v[0-9]+', r.get('name', ''))
                and r.get('approved_for_use') is True and fresh):
            errors.append('AMI_RECEIPT_INVALID')
    except (ValueError, TypeError, AttributeError):
        errors.append('AMI_RECEIPT_INVALID')
    return {'runtime_input_contract_valid': not errors, 'errors': errors,
            'AWS_verified_by_this_script': False, 'AWS_deployment': 'NO-GO'}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    g = p.add_mutually_exclusive_group()
    g.add_argument('--write', action='store_true', help='Write NONSECRET generated target files only')
    g.add_argument('--check-runtime', action='store_true', help='Inspect private environment, never print values')
    p.add_argument('--ami-receipt', type=Path, help='Nonsecret receipt from separately approved DescribeImages')
    args = p.parse_args()
    try:
        target = load_target()
        changes = sync_files(ROOT, target, args.write)
        if args.check_runtime:
            receipt = json.loads(args.ami_receipt.read_text()) if args.ami_receipt else None
            result = check_runtime(target, os.environ, receipt)
            if changes:
                result['errors'].append('GENERATED_TARGET_DRIFT')
                result['runtime_input_contract_valid'] = False
            print(json.dumps(result))
            return 0 if result['runtime_input_contract_valid'] else 2
        print(json.dumps({'nonsecret_files_match': not changes or args.write, 'changed_paths': changes,
                          'runtime_inputs_checked': False, 'AWS_calls': 0,
                          'AWS_deployment': 'NO-GO'}))
        return 0 if not changes or args.write else 2
    except InputError as error:
        print(json.dumps({'error_code': str(error), 'AWS_deployment': 'NO-GO'}))
        return 2
    except (OSError, ValueError, TypeError, KeyError):
        print(json.dumps({'error_code': 'INVALID_LOCAL_INPUT', 'AWS_deployment': 'NO-GO'}))
        return 2


if __name__ == '__main__':
    sys.exit(main())
