#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${ROOT_DIR}/out"
RELEASE_DIR="${OUT_DIR}/release"

mkdir -p "${RELEASE_DIR}"

# Copy repository layout while preventing recursive self-copy and excluding git metadata.
rsync -a --delete \
  --exclude='.git/' \
  --exclude='.git*' \
  --exclude='.github/' \
  --exclude='.editorconfig' \
  --exclude='.eslintrc.cjs' \
  --exclude='out/' \
  --exclude='create-release-bundle.sh' \
  "${ROOT_DIR}/" "${RELEASE_DIR}/"

# Remove development-only assets from release payload.
rm -f "${RELEASE_DIR}/create-release-bundle.sh"
rm -rf "${RELEASE_DIR}/tests"
rm -rf "${RELEASE_DIR}/.github"
rm -f "${RELEASE_DIR}/.editorconfig" "${RELEASE_DIR}/.eslintrc.cjs"
rm -f "${RELEASE_DIR}/.gitignore" "${RELEASE_DIR}/.gitmodules"

# Promote deploy scripts into the top-level Scripts folder for release consumers.
mkdir -p "${RELEASE_DIR}/Scripts"
if [[ -d "${RELEASE_DIR}/dist/Scripts" ]]; then
  rsync -a "${RELEASE_DIR}/dist/Scripts/" "${RELEASE_DIR}/Scripts/"
  rm -rf "${RELEASE_DIR}/dist/Scripts"
fi

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
