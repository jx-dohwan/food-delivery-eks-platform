#!/usr/bin/env python3
"""Check private input locally; create the exact Secret ONLY after separate approval."""
import argparse
import base64
import json
import os
import subprocess
import sys
from r2_target import InputError, load_target, valid_webhook


def secret_object(webhook):
    if not valid_webhook(webhook):
        raise InputError('PRIVATE_WEBHOOK_REQUIRED')
    return {'apiVersion': 'v1', 'kind': 'Secret',
            'metadata': {'name': 'logging-alerts', 'namespace': 'monitoring',
                         'labels': {'app.kubernetes.io/part-of': 'food-delivery',
                                    'food-delivery/environment': 'dev'}},
            'type': 'Opaque', 'data': {'slack-webhook': base64.b64encode(webhook.encode()).decode()}}


def create_secret(target, context, webhook, namespace_reviewed, run=None):
    # No implicit use of current context, no overwrite/apply/delete/Secret reads.
    expected = f"arn:aws:eks:{target['region']}:{target['account_id']}:cluster/{target['cluster_name']}"
    if context != expected or namespace_reviewed is not True:
        raise InputError('EXACT_CONTEXT_AND_NAMESPACE_APPROVAL_REQUIRED')
    obj = secret_object(webhook)
    invoke = run or subprocess.run
    child_env = {k: v for k, v in os.environ.items() if not k.startswith('TF_VAR_')}
    ns = invoke(['kubectl', '--context', context, 'get', 'namespace', 'monitoring', '-o', 'json'],
                text=True, capture_output=True, timeout=15, env=child_env)
    try:
        meta = json.loads(ns.stdout).get('metadata', {}) if ns.returncode == 0 else {}
        labels = meta.get('labels', {})
        if (meta.get('name') != 'monitoring' or labels.get('app.kubernetes.io/part-of') != 'food-delivery'
                or labels.get('food-delivery/environment') != 'dev'):
            raise InputError('NAMESPACE_OWNERSHIP_NOT_CONFIRMED')
    except (ValueError, TypeError, AttributeError):
        raise InputError('NAMESPACE_OWNERSHIP_NOT_CONFIRMED') from None
    # create refuses AlreadyExists. Do NOT fall back to apply/replace or log stderr.
    result = invoke(['kubectl', '--context', context, 'create', '-f', '-'],
                    input=json.dumps(obj), text=True, capture_output=True, timeout=15, env=child_env)
    if result.returncode:
        raise InputError('SECRET_CREATE_FAILED_NO_OVERWRITE_ATTEMPTED')
    return {'secret_created': True, 'notification_sent': False,
            'live_receiver_verified': False, 'AWS_deployment': 'NO-GO'}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--apply-secret', action='store_true', help='Requires separate Kubernetes mutation approval')
    p.add_argument('--context')
    p.add_argument('--namespace-reviewed', action='store_true')
    args = p.parse_args()
    try:
        target = load_target()
        webhook = os.environ.get('TF_VAR_slack_webhook_url', '')
        if not valid_webhook(webhook):
            raise InputError('PRIVATE_WEBHOOK_REQUIRED')
        if args.apply_secret:
            result = create_secret(target, args.context, webhook, args.namespace_reviewed)
        else:
            result = {'webhook_format_valid': True, 'Kubernetes_API_calls': 0,
                      'notification_sent': False, 'live_receiver_verified': False,
                      'AWS_deployment': 'NO-GO'}
        print(json.dumps(result))
        return 0
    except InputError as error:
        print(json.dumps({'error_code': str(error), 'AWS_deployment': 'NO-GO'}))
        return 2
    except (OSError, ValueError, TypeError, subprocess.SubprocessError):
        # Exceptions and process stderr can contain sensitive request details.
        print(json.dumps({'error_code': 'SECRET_PREPARATION_FAILED', 'AWS_deployment': 'NO-GO'}))
        return 2


if __name__ == '__main__':
    sys.exit(main())
