#!/usr/bin/env python3
"""Finite attended probe. No AWS calls, login/signup, token files or raw responses."""
import argparse
import datetime
import http.client
import http.cookies
import json
import math
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None

class Probe:
    def __init__(self, base, user_id, access, refresh='', timeout=5, opener=None):
        u = urllib.parse.urlsplit(base)
        if (u.scheme != 'https' or not u.hostname or u.username or u.password
                or u.query or u.fragment or u.path not in ('', '/')):
            raise ValueError('HTTPS origin only; no credentials, path, query or fragment')
        if not re.fullmatch(r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', user_id):
            raise ValueError('Expected own test user UUID')
        if not access or any(c in access + refresh for c in '\r\n;'):
            raise ValueError('Invalid in-memory credential')
        if not 0 < timeout <= 30:
            raise ValueError('timeout must be in (0,30]')
        self.user_id = user_id.lower()
        self.base, self.path, self.access, self.refresh = base.rstrip('/'), '/users/' + self.user_id, access, refresh
        self.timeout = timeout
        self.opener = opener or urllib.request.build_opener(NoRedirect())

    def request(self, path, headers=None, data=None):
        try:
            with self.opener.open(urllib.request.Request(self.base + path, headers=headers or {}, data=data), timeout=self.timeout) as response:
                return response.status, response.headers, response.read(65537)
        except urllib.error.HTTPError as error:
            return error.code, {}, b''  # Never log response bodies, URL, headers or exceptions.

    def profile_success(self, body):
        try:
            result = json.loads(body)
            return len(body) <= 65536 and result.get('success') is True and result['data']['id'] == self.user_id
        except (ValueError, TypeError, KeyError, AttributeError):
            return False

    def once(self):
        started = time.monotonic()
        sample = self._once()
        # Includes expired-access -> refresh -> profile round trip, and every
        # early rejection. Per-I/O timeout is NOT a total request deadline.
        elapsed = time.monotonic() - started
        sample['duration_ms'] = round(elapsed * 1000, 3)
        sample['sli_success'] = sample['result'] == 'success' and elapsed <= 5
        return sample

    def _once(self):
        started = time.monotonic()
        try:
            status, _, body = self.request(self.path, {'Authorization': 'Bearer ' + self.access})
            if status == 401 and self.refresh:
                status, headers, body = self.request('/auth/refresh', {'Cookie': 'refreshToken=' + self.refresh}, b'')
                if status == 200:
                    envelope = json.loads(body)
                    if envelope.get('success') is not True: raise ValueError('refresh API failed')
                    token = envelope['data']['accessToken']
                    if not isinstance(token, str) or not token or any(c in token for c in '\r\n'):
                        raise ValueError('invalid refresh reply')
                    cookie = http.cookies.SimpleCookie()
                    cookie.load(headers.get('Set-Cookie', ''))
                    if 'refreshToken' not in cookie:
                        raise ValueError('rotated refresh cookie missing')
                    rotated = cookie['refreshToken'].value
                    if not re.fullmatch(r'[A-Za-z0-9_.~-]+', rotated):
                        raise ValueError('invalid rotated cookie')
                    self.access, self.refresh = token, rotated
                    status, _, body = self.request(self.path, {'Authorization': 'Bearer ' + self.access})
                else:
                    return {'result': 'probe_auth_failed', 'status': status}
            if status == 200 and not self.profile_success(body):
                return {'result': 'unexpected_response', 'status': status}
            category = 'success' if status == 200 else 'probe_auth_failed' if status in (401, 403) else 'rate_limited' if status == 429 else 'http_error'
            return {'result': category, 'status': status, 'duration_ms': round((time.monotonic() - started) * 1000, 3)}
        except (TimeoutError, OSError, http.client.HTTPException):
            return {'result': 'transport_failure', 'duration_ms': round((time.monotonic() - started) * 1000, 3)}
        except (ValueError, KeyError, TypeError, http.cookies.CookieError):
            return {'result': 'probe_auth_failed'}

def observer_probe(name, url, timeout=5, opener=None):
    allowed = {'prometheus': '/-/ready', 'grafana': '/api/health', 'loki': '/ready', 'alloy': '/-/ready'}
    u = urllib.parse.urlsplit(url)
    if (name not in allowed or u.scheme != 'http' or u.hostname not in ('127.0.0.1', 'localhost')
        or u.path != allowed[name] or u.username or u.password or u.query or u.fragment):
        raise ValueError('Observer probes must target known loopback health paths')
    try:
        with (opener or urllib.request.build_opener(NoRedirect())).open(url, timeout=timeout) as response:
            return {'observer': name, 'healthy': response.status == 200}
    except (OSError, TimeoutError, http.client.HTTPException):
        return {'observer': name, 'healthy': False}

def check_artifacts(data):
    """Validates supplied snapshots. It neither fetches live data nor authenticates provenance."""
    sha = data.get('source_sha', '')
    revision = data.get('gitops_revision', '')
    digests = data.get('digests', {})
    if (not re.fullmatch('[a-f0-9]{40}', sha) or not re.fullmatch('[a-f0-9]{40}', revision)
        or set(digests) != {'was', 'web'} or not all(re.fullmatch('sha256:[a-f0-9]{64}', d) for d in digests.values())):
        raise ValueError('Invalid source/digest contract')
    observed = datetime.datetime.fromisoformat(data.get('observed_at', '').replace('Z', '+00:00'))
    if observed.tzinfo is None or not 0 <= (datetime.datetime.now(datetime.timezone.utc)-observed).total_seconds() <= 600:
        raise ValueError('Fresh timezone-aware snapshots required')
    app = data.get('application', {})
    if app.get('metadata', {}).get('name') != 'food-delivery-dev' or app.get('spec', {}).get('destination', {}).get('namespace') != 'app':
        raise ValueError('Wrong Application destination')
    status = app.get('status', {})
    if status.get('sync', {}).get('status') != 'Synced' or status.get('sync', {}).get('revision') != revision:
        raise ValueError('Sync revision mismatch')
    operation = status.get('operationState', {})
    result = operation.get('syncResult', {})
    if status.get('health', {}).get('status') != 'Healthy' or operation.get('phase') != 'Succeeded' or result.get('revision') != revision:
        raise ValueError('Deployment not healthy/completed at expected revision')
    if not any(r.get('kind')=='Job' and r.get('name')=='was-db-migration' and r.get('namespace')=='app' and r.get('hookPhase')=='Succeeded' for r in result.get('resources', [])):
        raise ValueError('Migration hook success evidence missing')
    counts={'was': 0, 'web': 0}
    seen_names=set(); seen_uids=set()
    for pod in data.get('pods', {}).get('items', []):
        meta=pod.get('metadata', {}); role=meta.get('labels', {}).get('app')
        if role not in counts or meta.get('deletionTimestamp'): continue
        name=meta.get('name', ''); uid=meta.get('uid', '')
        if not name or not uid or name in seen_names or uid in seen_uids:
            raise ValueError('Distinct Pod name/UID required')
        seen_names.add(name); seen_uids.add(uid)
        ps=pod.get('status', {})
        if meta.get('namespace')!='app' or ps.get('phase')!='Running' or not any(c.get('type')=='Ready' and c.get('status')=='True' for c in ps.get('conditions', [])):
            raise ValueError('Expected workload Pod is not ready')
        containers=[c for c in pod.get('spec', {}).get('containers', []) if c.get('name')==role]
        statuses=[c for c in ps.get('containerStatuses', []) if c.get('name')==role]
        if len(containers)!=1 or len(statuses)!=1 or not containers[0].get('image', '').endswith('/'+role+':'+sha):
            raise ValueError('Workload image tag/source mismatch')
        state=statuses[0]
        if (state.get('ready') is not True or 'running' not in state.get('state', {})
            or not re.search(r'(?:@|://)'+re.escape(digests[role])+r'$',state.get('imageID',''))):
            raise ValueError('Actual container digest/state mismatch')
        counts[role]+=1
    if any(n<2 for n in counts.values()):raise ValueError('Minimum workload replicas missing')
    return {'snapshot_contract_valid': True, 'live_verified': False, 'ready_role_counts': counts}

def check_preflight(data):
    """Validates supplied evidence declarations, NOT a live AWS/Secret check."""
    required = ['cloudwatch_enabled', 'sns_receiver_verified', 'alertmanager_secret_verified',
                'retention_approved', 'cost_approved']
    if any(data.get(k) is not True for k in required):
        raise ValueError('Approval/notification declarations incomplete; deployment remains NO-GO')
    if not re.fullmatch('[a-f0-9]{40}', data.get('source_sha', '')):
        raise ValueError('Source SHA missing')
    if not re.fullmatch('[a-f0-9]{40}', data.get('gitops_revision', '')):
        raise ValueError('GitOps revision missing')
    if set(data.get('digests', {})) != {'was', 'web'} or not all(re.fullmatch('sha256:[a-f0-9]{64}', d) for d in data['digests'].values()):
        raise ValueError('WAS/Web digest contract missing')
    return {'declarations_valid': True, 'live_verified': False}

def session_summary(samples, duration, interval):
    planned = math.ceil(duration / interval)
    attempts = len(samples)
    successes = sum(row.get('sli_success') is True for row in samples)
    categories = {}
    for row in samples:
        category = row['result']
        categories[category] = categories.get(category, 0) + 1
    return {'type': 'session_summary', 'planned_attempts': planned, 'actual_attempts': attempts,
            'sli_successes': successes, 'sli_success_ratio': successes / attempts if attempts else None,
            'coverage_ratio': min(1, attempts / planned), 'categories': categories,
            'measurement_complete': attempts >= planned and not categories.get('probe_auth_failed', 0),
            'slo_attainment': 'NOT_EVALUATED'}

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--artifact-report', help='Fresh Argo Application/Pod JSON plus source/digest contract; no API calls')
    p.add_argument('--preflight', help='Local declaration JSON; not an AWS API check')
    p.add_argument('--observer', action='append', default=[], help='name=http://127.0.0.1:PORT/health-path; finite local port-forward only')
    p.add_argument('--base'); p.add_argument('--user-id')
    p.add_argument('--duration', type=int); p.add_argument('--timeout', type=float, default=5)
    p.add_argument('--interval', type=float, default=1)
    a = p.parse_args()
    try:
        if a.artifact_report:
            with open(a.artifact_report) as f: print(json.dumps(check_artifacts(json.load(f))))
            return 0
        if a.preflight:
            with open(a.preflight) as f: print(json.dumps(check_preflight(json.load(f))))
            return 0
        if not a.duration or not 0 < a.duration <= 10800 or not math.isfinite(a.interval) or a.interval < 1:
            raise ValueError('Explicit duration 1..10800 seconds and interval >=1 required')
        probe = Probe(a.base or '', a.user_id or '', os.environ.get('PROBE_ACCESS_TOKEN', ''), os.environ.get('PROBE_REFRESH_TOKEN', ''), a.timeout)
        observers = [value.split('=', 1) for value in a.observer]
        if any(len(pair) != 2 for pair in observers): raise ValueError('invalid observer')
        end = time.monotonic() + a.duration
        attempts = 0
        samples = []
        while time.monotonic() < end:
            sample = probe.once(); attempts += 1
            samples.append(sample)
            sample['observers'] = [observer_probe(name, url, a.timeout) for name, url in observers]
            print(json.dumps({'utc': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'attempt': attempts, **sample}), flush=True)
            if sample['result'] == 'probe_auth_failed':
                print(json.dumps(session_summary(samples, a.duration, a.interval)), flush=True)
                return 2
            remaining = end - time.monotonic()
            if remaining > 0: time.sleep(min(a.interval, remaining))
        print(json.dumps(session_summary(samples, a.duration, a.interval)), flush=True)
        return 0
    except (ValueError, TypeError, OSError, KeyError, AttributeError):
        print(json.dumps({'result': 'invalid_probe_configuration'}))
        return 2

if __name__ == '__main__':
    raise SystemExit(main())
