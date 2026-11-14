"""Synthetic-clock probe policy tests. No API calls or credentials."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('policyprobe', Path(__file__).with_name('observability-session-probe.py'))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

class PolicyTests(unittest.TestCase):
    def instance(self):
        return probe.Probe('https://example.test', '00000000-0000-4000-8000-000000000001', 'synthetic')

    def test_every_category_has_total_elapsed_and_sli_success(self):
        for category in ['success', 'unexpected_response', 'probe_auth_failed', 'rate_limited', 'transport_failure', 'http_error']:
            p = self.instance()
            with patch.object(p, '_once', return_value={'result': category}), patch.object(probe.time, 'monotonic', side_effect=[10, 10.25]):
                result = p.once()
            self.assertEqual(result['duration_ms'], 250)
            self.assertEqual(result['sli_success'], category == 'success')

    def test_slow_success_is_not_five_second_business_success(self):
        p = self.instance()
        with patch.object(p, '_once', return_value={'result': 'success'}), patch.object(probe.time, 'monotonic', side_effect=[10, 16]):
            result = p.once()
        self.assertEqual(result['result'], 'success')
        self.assertFalse(result['sli_success'])

    def test_five_second_boundary(self):
        p = self.instance()
        with patch.object(p, '_once', return_value={'result': 'success'}), patch.object(probe.time, 'monotonic', side_effect=[10, 15]):
            self.assertTrue(p.once()['sli_success'])

    def test_missing_traffic_not_zero_errors_or_slo_success(self):
        result = probe.session_summary([], 600, 10)
        self.assertIsNone(result['sli_success_ratio'])
        self.assertFalse(result['measurement_complete'])
        self.assertEqual(result['coverage_ratio'], 0)
        self.assertEqual(result['slo_attainment'], 'NOT_EVALUATED')

    def test_incomplete_coverage_cannot_prove_slo(self):
        samples = [{'result': 'success', 'sli_success': True}] * 59
        result = probe.session_summary(samples, 600, 10)
        self.assertEqual(result['sli_success_ratio'], 1)
        self.assertFalse(result['measurement_complete'])

    def test_auth_tool_failure_distinct_from_service_error(self):
        result = probe.session_summary([{'result': 'probe_auth_failed', 'sli_success': False}], 1, 1)
        self.assertFalse(result['measurement_complete'])
        self.assertEqual(result['categories'], {'probe_auth_failed': 1})

    def test_full_smoke_is_observation_not_achieved_long_term_slo(self):
        result = probe.session_summary([{'result': 'success', 'sli_success': True}] * 60, 600, 10)
        self.assertTrue(result['measurement_complete'])
        self.assertEqual(result['slo_attainment'], 'NOT_EVALUATED')

if __name__ == '__main__': unittest.main()
