#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${ROOT_DIR}/out"
RELEASE_DIR="${OUT_DIR}/release"

# Default allowlist extensions for curated folder copies.
ALLOWED_EXTENSIONS=("ps1" "psm1" "psd1" "md" "json")

# Curated runtime directories copied with extension allowlist.
declare -a ALLOWLIST_DIRS=(
  "core"
  "connectors"
  "Scripts"
)

# Required runtime paths copied exactly as files/directories (if present).
declare -a REQUIRED_PATHS=(
  "config"
  "drop"
  "log"
  "logs"
  "setup"
  "certificate.env"
  "dist/certificate.env.example"
  "certificate-backup.ps1"
  "certificate-orchestrator.ps1"
  "certificate-restore.ps1"
  "certificate-setup.ps1"
  "certificate-simple-acme-reconcile.ps1"
  "config.ps1"
  "dist/public_suffix_list.dat"
  "settings.json"
  "settings_default.json"
  "version.txt"
  "wacs.exe"
  "dist/Web_Config.xml"
  "README.md"
  "LICENSE"
  "instructions.md"
  "install.md"
)

rm -rf "${RELEASE_DIR}"
mkdir -p "${RELEASE_DIR}"

copy_allowlisted_dir() {
  local src_dir="$1"
  [[ -d "${ROOT_DIR}/${src_dir}" ]] || return 0

  while IFS= read -r rel_path; do
    mkdir -p "${RELEASE_DIR}/$(dirname "${rel_path}")"
    cp "${ROOT_DIR}/${rel_path}" "${RELEASE_DIR}/${rel_path}"
  done < <(
    find "${ROOT_DIR}/${src_dir}" -type f \
      \( -name "*.ps1" -o -name "*.psm1" -o -name "*.psd1" -o -name "*.md" -o -name "*.json" \) \
      -not -path "*/tests/*" \
      -not -path "*/build/*" \
      -not -path "*/docs/*" \
      -not -path "*/.git/*" \
      | sed "s#^${ROOT_DIR}/##" \
      | LC_ALL=C sort
  )
}

for dir_name in "${ALLOWLIST_DIRS[@]}"; do
  copy_allowlisted_dir "${dir_name}"
done

for rel_path in "${REQUIRED_PATHS[@]}"; do
  src="${ROOT_DIR}/${rel_path}"
  dest="${RELEASE_DIR}/${rel_path}"

  if [[ -d "${src}" ]]; then
    mkdir -p "${dest}"
    find "${src}" -type f | while IFS= read -r src_file; do
      child_rel="${src_file#${ROOT_DIR}/}"
      mkdir -p "${RELEASE_DIR}/$(dirname "${child_rel}")"
      cp "${src_file}" "${RELEASE_DIR}/${child_rel}"
    done
  elif [[ -f "${src}" ]]; then
    mkdir -p "${RELEASE_DIR}/$(dirname "${rel_path}")"
    cp "${src}" "${dest}"
  fi
done

if [[ -f "${RELEASE_DIR}/install.md" && ! -f "${RELEASE_DIR}/instructions.md" ]]; then
  cp "${RELEASE_DIR}/install.md" "${RELEASE_DIR}/instructions.md"
fi

# Validate: block dangerous file types except explicit required runtime files.
forbidden_files="$(find "${RELEASE_DIR}" -type f \( -name "*.cs" -o -name "*.yml" -o -name "*.yaml" -o -name "*.dll" \))"
if [[ -n "${forbidden_files}" ]]; then
  echo "ERROR: Forbidden file types found in release bundle:" >&2
  printf '%s\n' "${forbidden_files}" >&2
  exit 1
fi

# Validate: allow normal allowlisted extensions plus explicit required exceptions.
non_allowlisted="$(find "${RELEASE_DIR}" -type f | while IFS= read -r file; do
  base="$(basename "${file}")"
  case "${base}" in
    LICENSE|public_suffix_list.dat|certificate.env|wacs.exe|Web_Config.xml|version.txt)
      continue
      ;;
  esac
  ext="${base##*.}"
  [[ "${base}" == "${ext}" ]] && { echo "${file}"; continue; }
  ok=false
  for allowed_ext in "${ALLOWED_EXTENSIONS[@]}"; do
    [[ "${ext}" == "${allowed_ext}" ]] && ok=true && break
  done
  [[ "${ok}" == false ]] && echo "${file}"
done)"

if [[ -n "${non_allowlisted}" ]]; then
  echo "ERROR: Non-allowlisted files found in release bundle:" >&2
  printf '%s\n' "${non_allowlisted}" >&2
  exit 1
fi

echo "Release bundle created at ${RELEASE_DIR}"
echo "Included files:"
find "${RELEASE_DIR}" -type f | LC_ALL=C sort

echo "Total file count: $(find "${RELEASE_DIR}" -type f | wc -l | tr -d ' ')"
echo "Total size: $(du -sh "${RELEASE_DIR}" | cut -f1)"
