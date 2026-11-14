#!/usr/bin/env python3
"""Native local PromQL/alert behavior tests. Requires PyYAML and pinned promtool."""
import argparse
from pathlib import Path
import subprocess
import tempfile
import yaml

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--promtool',required=True,type=Path);a=p.parse_args()
    root=Path(__file__).resolve().parents[1]
    config=yaml.safe_load((root/'infra/modules/eks/logging/alerting-values.yaml').read_text())
    groups=[g for entry in config['additionalPrometheusRulesMap'].values() for g in entry['groups']]
    fixtures=yaml.safe_load((root/'scripts/tests/observability-alerts.test.yml').read_text())
    with tempfile.TemporaryDirectory(prefix='food-promql-local-') as directory:
        folder=Path(directory);(folder/'observability-rules.generated.yaml').write_text(yaml.safe_dump({'groups':groups},sort_keys=False))
        (folder/'tests.yml').write_text(yaml.safe_dump(fixtures,sort_keys=False))
        for args in [('check','rules','observability-rules.generated.yaml'),('test','rules','tests.yml')]:
            result=subprocess.run([str(a.promtool.resolve()),*args],cwd=folder,check=False)
            if result.returncode:return result.returncode
    return 0
if __name__=='__main__':raise SystemExit(main())
