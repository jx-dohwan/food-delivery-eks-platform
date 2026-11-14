#!/usr/bin/env bash
# Prepare the archive_file source directory. No AWS calls or Lambda invocation.
set -euo pipefail
rotation_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package_temp="$(mktemp -d "${rotation_dir}/.package.XXXXXX")"
trap 'rm -rf "$package_temp"' EXIT

"${PYTHON_BIN:-python3}" -m pip install --no-deps --no-compile \
  --only-binary=:all: --require-hashes --target "$package_temp" \
  -r "$rotation_dir/requirements.txt"
cp "$rotation_dir/lambda_function.py" "$rotation_dir/rds-ca-bundle.pem" "$package_temp/"
# build/ contains generated artifacts only; replace it to remove stale packages.
rm -rf "${rotation_dir:?}/build"
mv "$package_temp" "$rotation_dir/build"
trap - EXIT
echo "Rotation package prepared: $rotation_dir/build"
