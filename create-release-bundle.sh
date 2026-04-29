#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${ROOT_DIR}/out"
RELEASE_DIR="${OUT_DIR}/release"

# Allowed runtime file extensions.
ALLOWED_EXTENSIONS=("ps1" "psm1" "psd1" "md" "json")

# Paths to copy into release (source_dir:target_subdir).
declare -a COPY_MAP=(
  "core:core"
  "connectors:connectors"
  "Scripts:scripts"
  "scripts:scripts"
)

# Reset output directory to ensure deterministic builds.
rm -rf "${RELEASE_DIR}"
mkdir -p "${RELEASE_DIR}/core" "${RELEASE_DIR}/connectors" "${RELEASE_DIR}/scripts"

copy_allowlisted_files() {
  local src_dir="$1"
  local dest_dir="$2"

  [[ -d "${src_dir}" ]] || return 0

  while IFS= read -r rel_path; do
    mkdir -p "${dest_dir}/$(dirname "${rel_path}")"
    cp "${src_dir}/${rel_path}" "${dest_dir}/${rel_path}"
  done < <(
    find "${src_dir}" -type f \
      \( -name "*.ps1" -o -name "*.psm1" -o -name "*.psd1" -o -name "*.md" -o -name "*.json" \) \
      -not -path "*/tests/*" \
      -not -path "*/build/*" \
      -not -path "*/dist/*" \
      -not -path "*/docs/*" \
      -not -path "*/setup/*" \
      -not -path "*/.git/*" \
      -not -name ".git*" \
      -not -name ".editorconfig" \
      -not -name ".eslintrc*" \
      | sed "s#^${src_dir}/##" \
      | LC_ALL=C sort
  )
}

for mapping in "${COPY_MAP[@]}"; do
  src="${mapping%%:*}"
  dst="${mapping##*:}"
  copy_allowlisted_files "${ROOT_DIR}/${src}" "${RELEASE_DIR}/${dst}"
done

# Copy explicitly allowed root-level files only when present.
for root_file in "README.md" "LICENSE" "config.json"; do
  if [[ -f "${ROOT_DIR}/${root_file}" ]]; then
    cp "${ROOT_DIR}/${root_file}" "${RELEASE_DIR}/${root_file}"
  fi
done

# Validation 1: ensure no forbidden file types are present.
forbidden_files="$(find "${RELEASE_DIR}" -type f \( -name "*.cs" -o -name "*.yml" -o -name "*.yaml" -o -name "*.dll" -o -name "*.exe" \))"
if [[ -n "${forbidden_files}" ]]; then
  echo "ERROR: Forbidden file types found in release bundle:" >&2
  printf '%s\n' "${forbidden_files}" >&2
  exit 1
fi

# Validation 2: ensure every file extension is explicitly allowlisted.
non_allowlisted="$(find "${RELEASE_DIR}" -type f | while IFS= read -r file; do
  filename="$(basename "${file}")"
  case "${filename}" in
    LICENSE)
      continue
      ;;
  esac

  ext="${filename##*.}"
  if [[ "${filename}" == "${ext}" ]]; then
    echo "${file}"
    continue
  fi

  allowed=false
  for allowed_ext in "${ALLOWED_EXTENSIONS[@]}"; do
    if [[ "${ext}" == "${allowed_ext}" ]]; then
      allowed=true
      break
    fi
  done

  if [[ "${allowed}" == false ]]; then
    echo "${file}"
  fi
done)"

if [[ -n "${non_allowlisted}" ]]; then
  echo "ERROR: Non-allowlisted files found in release bundle:" >&2
  printf '%s\n' "${non_allowlisted}" >&2
  exit 1
fi

# Reporting.
echo "Release bundle created at ${RELEASE_DIR}"
echo "Included files:"
find "${RELEASE_DIR}" -type f | LC_ALL=C sort

echo "Total file count: $(find "${RELEASE_DIR}" -type f | wc -l | tr -d ' ')"
echo "Total size: $(du -sh "${RELEASE_DIR}" | cut -f1)"
