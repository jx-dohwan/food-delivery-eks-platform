#!/usr/bin/env bash
# Run only after both scanned images were published successfully.
set -euo pipefail

: "${SOURCE_SHA:?SOURCE_SHA is required}"
: "${GITHUB_REF:?GITHUB_REF is required}"
if [[ "$GITHUB_REF" != "refs/heads/main" ]]; then
  echo "Tag builds publish images only; no dev/prod manifest promotion."
  exit 0
fi
if [[ ! "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "SOURCE_SHA must be a full Git commit SHA" >&2
  exit 1
fi

git fetch origin main
if ! git merge-base --is-ancestor "$SOURCE_SHA" origin/main; then
  echo "Source commit is no longer on main; skip outdated deployment."
  exit 0
fi
# A newer build-input commit must win, even if it later reverted the same files.
newer_source=$(git log -1 --format=%H "$SOURCE_SHA..origin/main" -- \
  app .github/workflows/deploy.yml scripts/ci)
if [[ -n "$newer_source" ]]; then
  echo "Newer source commit exists; skip outdated deployment."
  exit 0
fi

# Preserve manifest/documentation changes made while the images were building.
git checkout -B main origin/main
bash scripts/ci/update-images.sh k8s/overlays/dev
git add k8s/overlays/dev/kustomization.yaml
if git diff --staged --quiet; then
  echo "No manifest changes to commit."
  exit 0
fi
git -c user.name='github-actions[bot]' \
  -c user.email='github-actions[bot]@users.noreply.github.com' \
  commit -m "chore(gitops): deploy ${SOURCE_SHA} to dev [skip ci]" \
  -m "Source-Commit: ${SOURCE_SHA}
WAS-Image: was:${SOURCE_SHA}
WEB-Image: web:${SOURCE_SHA}
WAS-Digest: ${WAS_DIGEST:?WAS_DIGEST is required}
WEB-Digest: ${WEB_DIGEST:?WEB_DIGEST is required}"
# Never force push. If main advanced after fetch, fail instead of losing changes.
git push origin HEAD:main
