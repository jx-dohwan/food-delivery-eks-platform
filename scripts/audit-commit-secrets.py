#!/usr/bin/env python3
"""Scan tracked + non-ignored candidates; report paths/lines/types, never values.

Heuristic check, not a claim that arbitrary passwords can be detected. Local
ignored tfvars/state/env must be reviewed separately without printing their values.
"""
from pathlib import Path
import re
import subprocess
import sys

PATTERNS = {
    "SLACK_WEBHOOK": r"https://hooks\.slack\.com/services/T[A-Z0-9]{7,}/B[A-Z0-9]{7,}/[A-Za-z0-9]{20,}",
    "AWS_ACCESS_ID": r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b",
    "PRIVATE_KEY": r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
    "STATIC_AWS_SECRET": r'''(?:AWS_SECRET_ACCESS_KEY|secretAccessKey)\s*[:=]\s*["'][A-Za-z0-9/+=]{40}["']''',
}


def findings(text):
    for kind, pattern in PATTERNS.items():
        for match in re.finditer(pattern, text):
            yield text.count("\n", 0, match.start()) + 1, kind


def main():
    names = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"]).decode().split("\0")
    count = 0
    for name in sorted(set(names)):
        path = Path(name)
        if not path.is_file():
            continue
        try:
            text = path.read_text()
        except (OSError, UnicodeError):
            continue
        for line, kind in findings(text):
            print(f"{name}:{line}: {kind} [value suppressed]")
            count += 1
    print(f"Commit-candidate secret-pattern findings: {count}; values never printed")
    return bool(count)


if __name__ == "__main__":
    sys.exit(main())
