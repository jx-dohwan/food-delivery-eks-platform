#!/usr/bin/env bash
# The CI role can query manifests with BatchGetImage; no ECR admin/read expansion.
set -euo pipefail

: "${SOURCE_SHA:?SOURCE_SHA is required}"
: "${ECR_REGISTRY:?ECR_REGISTRY is required}"
if [[ ! "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "SOURCE_SHA must be a full Git commit SHA" >&2
  exit 1
fi
mode="${1:-publish}"
if [[ "$mode" != check && "$mode" != publish ]]; then
  echo "Usage: publish-images.sh [check|publish]" >&2
  exit 1
fi

# Refuse to overwrite either SHA, including reruns and main/tag runs of one commit.
for component in was web; do
  result=$(aws ecr batch-get-image --repository-name "$component" \
    --image-ids "imageTag=${SOURCE_SHA}" --output json)
  if ! jq -e '(.images | length) == 0 and
    all(.failures[]; .failureCode == "ImageNotFound")' <<< "$result" >/dev/null; then
    echo "${component}:${SOURCE_SHA} exists or cannot be verified; refusing to overwrite." >&2
    exit 1
  fi
done
if [[ "$mode" == check ]]; then
  exit 0
fi

# Both local images must carry the revision of the checked-out, scanned source.
for component in was web; do
  image="${ECR_REGISTRY}/${component}:${SOURCE_SHA}"
  revision=$(docker image inspect "$image" \
    --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')
  if [[ "$revision" != "$SOURCE_SHA" ]]; then
    echo "${component} image revision does not match source commit." >&2
    exit 1
  fi
done

for component in was web; do
  image="${ECR_REGISTRY}/${component}:${SOURCE_SHA}"
  # Push the exact local image already scanned by Trivy; never rebuild here.
  push_output=$(docker push "$image")
  printf '%s\n' "$push_output"
  if [[ ! "$push_output" =~ digest:\ (sha256:[0-9a-f]{64}) ]]; then
    echo "Docker push did not report a registry digest for ${component}" >&2
    exit 1
  fi
  pushed_digest="${BASH_REMATCH[1]}"
  # Read back the ECR manifest digest, not the unrelated local image/config ID.
  digest=$(aws ecr batch-get-image --repository-name "$component" \
    --image-ids "imageTag=${SOURCE_SHA}" --output json |
    jq -er '.images[0].imageId.imageDigest')
  if [[ "$digest" != "$pushed_digest" ]]; then
    echo "ECR digest does not match the published image for ${component}" >&2
    exit 1
  fi
  printf '%s_digest=%s\n' "$component" "$digest" >> "${GITHUB_OUTPUT:?}"
  printf '%s: `%s` → `%s`\n' "$component" "$image" "$digest" >> "${GITHUB_STEP_SUMMARY:?}"
done
