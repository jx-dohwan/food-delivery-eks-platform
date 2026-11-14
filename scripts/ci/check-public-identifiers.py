#!/usr/bin/env python3
"""Fail if a tracked file contains a real account/infrastructure identifier or a credential.

Two layers:
  1. Generic rules: AWS account IDs inside ARNs/ECR hosts, AWS resource IDs, access keys,
     tokens, private keys, Slack webhooks. Documented fake values are allowed.
  2. Exact deny values (account ID, domain, email, bucket names...) supplied through the
     environment variable PUBLIC_IDENTIFIER_DENYLIST (newline separated) or --denylist-file.
     In CI they come from repository secrets; locally from a git-ignored file.

Only file:line and the rule name are printed, never the matched value.
"""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys

FAKE_ACCOUNTS = {"000000000000", "123456789012", "111111111111", "999999999999", "111122223333", "444455556666", "602401143452"}
# 111122223333 and 444455556666 are the example account IDs used throughout the AWS documentation.
# 602401143452 is the public AWS account that publishes the official EKS AMIs/images.
FAKE_RESOURCE = re.compile(r"-0{8,17}\d?$|-0123456789abcdef0$|-0+[1-9]$")

RULES = [
    ("aws-account-in-arn", re.compile(r"arn:aws[a-z-]*:[a-z0-9-]+:[a-z0-9-]*:(\d{12}):")),
    ("aws-account-in-ecr", re.compile(r"\b(\d{12})\.dkr\.ecr\.")),
    ("aws-resource-id", re.compile(r"\b((?:vpc|subnet|sg|vol|vpce|igw|nat|rtb|eni|i|lt)-0[0-9a-f]{7,16})\b")),
    ("aws-access-key", re.compile(r"\b((?:AKIA|ASIA)[A-Z0-9]{16})\b")),
    ("github-token", re.compile(r"\b((?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{50,})")),
    ("slack-token", re.compile(r"\b(xox[abposr]-[A-Za-z0-9-]{10,})")),
    ("slack-webhook", re.compile(r"(hooks\.slack\.com/services/T[A-Z0-9]{8,}/B[A-Z0-9]{8,}/[A-Za-z0-9]{20,})")),
    ("private-key", re.compile(r"(-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----)")),
    ("local-home-path", re.compile(r"(/Users/[A-Za-z0-9._-]+/|/home/(?!runner/)[A-Za-z0-9._-]+/)")),
    ("literal-upload-bucket", re.compile(r'''\bAWS_S3_BUCKET_NAME\b["']?\s*[:=]\s*["']?([a-z0-9][a-z0-9.-]{2,62})(?=["']|$|\s+#)''')),
]


def allowed(rule, value):
    if rule in ("aws-account-in-arn", "aws-account-in-ecr"):
        return value in FAKE_ACCOUNTS
    if rule == "aws-resource-id":
        return bool(FAKE_RESOURCE.search(value))
    if rule == "literal-upload-bucket":
        return value == "injected-at-deploy" or value.startswith(("example-", "test-", "mock-", "synthetic-", "fixture-"))
    return False


def sensitive_filename(rel):
    name = Path(rel).name
    if ".example" in name:
        return False
    return (
        name == ".env" or name.startswith(".env.")
        or ".tfstate" in name
        or name.endswith((".tfvars", ".tfvars.json", ".tfplan", ".key", ".p12", ".pfx"))
        or name in {"backend.hcl", "backend.r2.hcl", "credentials", "id_rsa", "id_ed25519"}
        or name.startswith("kubeconfig")
        or rel in {"config/r2-dev-target.json", "config/prod-target.json"}
    )


def tracked_files(root):
    out = subprocess.run(["git", "-C", str(root), "ls-files", "-z"], capture_output=True, check=True).stdout
    return [p for p in out.decode().split("\0") if p]


def scan(root, deny):
    findings = []
    for rel in tracked_files(root):
        path = root / rel
        if sensitive_filename(rel):
            findings.append((rel, 1, "tracked-sensitive-file"))
        try:
            data = path.read_bytes()
        except OSError:
            continue
        if b"\0" in data[:8192]:
            continue
        text = data.decode("utf-8", errors="replace")
        for number, line in enumerate(text.splitlines(), 1):
            for name, rule in RULES:
                for match in rule.finditer(line):
                    if not allowed(name, match.group(1)):
                        findings.append((rel, number, name))
            lowered = line.lower()
            for index, value in enumerate(deny):
                if value.lower() in lowered:
                    findings.append((rel, number, f"denylist-entry-{index + 1}"))
    return findings


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--denylist-file", type=Path, help="git-ignored file, one exact value per line")
    args = parser.parse_args()
    raw = os.environ.get("PUBLIC_IDENTIFIER_DENYLIST", "")
    if args.denylist_file:
        raw += "\n" + args.denylist_file.read_text()
    deny = sorted({v.strip() for v in raw.splitlines() if len(v.strip()) >= 6 and not v.strip().startswith("#")})
    findings = scan(args.root.resolve(), deny)
    for rel, number, name in findings:
        print(f"{rel}:{number}: {name}")
    print(f"checked tracked files with {len(RULES)} generic rules and {len(deny)} exact values; findings: {len(findings)}")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
