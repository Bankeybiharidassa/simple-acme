#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${ROOT_DIR}/out"
RELEASE_DIR="${OUT_DIR}/release"

mkdir -p "${RELEASE_DIR}"

# Copy the full repository layout (files + directories, including empty ones)
# while preventing recursive self-copy and excluding git metadata.
rsync -a --delete \
  --exclude='.git/' \
  --exclude='out/' \
  --exclude='create-release-bundle.sh' \
  "${ROOT_DIR}/" "${RELEASE_DIR}/"

# Remove files intentionally excluded from release payload.
rm -f "${RELEASE_DIR}/create-release-bundle.sh"

# Normalize release docs that downstream consumers usually expect.
if [[ -f "${RELEASE_DIR}/install.md" && ! -f "${RELEASE_DIR}/instructions.md" ]]; then
  cp "${RELEASE_DIR}/install.md" "${RELEASE_DIR}/instructions.md"
fi

for required in "README.md" "LICENSE" "instructions.md"; do
  if [[ ! -f "${RELEASE_DIR}/${required}" ]]; then
    echo "Missing required release file: ${required}" >&2
    exit 1
  fi
done

echo "Release bundle created at ${RELEASE_DIR}"
