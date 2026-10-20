#!/usr/bin/env bash
set -euo pipefail

# Vaani Model & Framework Setup Script
# Downloads and prepares:
#   1. Kokoro int8 multi-lang TTS model (kokoro-int8-multi-lang-v1_0) for sherpa-onnx
#   2. WhisperKit CoreML model (openai_whisper-small) from argmaxinc/whisperkit-coreml
#   3. sherpa-onnx iOS XCFrameworks (Staging/build-ios) if not already present

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STAGING_DIR="${REPO_ROOT}/Staging"

KOKORO_FOLDER_NAME="kokoro-int8-multi-lang-v1_0"
KOKORO_ARCHIVE="${STAGING_DIR}/${KOKORO_FOLDER_NAME}.tar.bz2"
KOKORO_DIR="${STAGING_DIR}/${KOKORO_FOLDER_NAME}"
KOKORO_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-int8-multi-lang-v1_0.tar.bz2"

WHISPER_VARIANT="openai_whisper-small"
WHISPER_DIR="${STAGING_DIR}/${WHISPER_VARIANT}"
HF_REPO="argmaxinc/whisperkit-coreml"
HF_BASE_URL="https://huggingface.co/${HF_REPO}/resolve/main/${WHISPER_VARIANT}"

mkdir -p "${STAGING_DIR}"

echo "============================================================"
echo "Vaani Model Setup"
echo "Staging directory: ${STAGING_DIR}"
echo "============================================================"

# ------------------------------------------------------------------------------
# 1. Kokoro int8 multi-lang model (kokoro-int8-multi-lang-v1_0)
# ------------------------------------------------------------------------------
KOKORO_REQUIRED_FILES=(
  "model.int8.onnx"
  "voices.bin"
  "tokens.txt"
  "lexicon-us-en.txt"
)

kokoro_ready=true
for f in "${KOKORO_REQUIRED_FILES[@]}"; do
  if [[ ! -f "${KOKORO_DIR}/${f}" ]]; then
    kokoro_ready=false
    break
  fi
done
if [[ ! -d "${KOKORO_DIR}/espeak-ng-data" ]]; then
  kokoro_ready=false
fi

if [[ "${kokoro_ready}" == "true" ]]; then
  echo "[1/2] Kokoro model already present at ${KOKORO_DIR} — skipping download."
else
  echo "[1/2] Preparing Kokoro model (${KOKORO_FOLDER_NAME})..."
  if [[ ! -f "${KOKORO_ARCHIVE}" ]]; then
    echo "  -> Downloading ${KOKORO_URL}..."
    curl -L --fail --retry 3 --progress-bar -o "${KOKORO_ARCHIVE}.part" "${KOKORO_URL}"
    mv "${KOKORO_ARCHIVE}.part" "${KOKORO_ARCHIVE}"
  else
    echo "  -> Archive ${KOKORO_ARCHIVE} already exists — skipping download."
  fi

  echo "  -> Extracting ${KOKORO_ARCHIVE} into ${STAGING_DIR}..."
  tar -xjf "${KOKORO_ARCHIVE}" -C "${STAGING_DIR}"
fi

# ------------------------------------------------------------------------------
# 2. WhisperKit CoreML model (openai_whisper-small)
# ------------------------------------------------------------------------------
WHISPER_REQUIRED_DIRS=(
  "MelSpectrogram.mlmodelc"
  "AudioEncoder.mlmodelc"
  "TextDecoder.mlmodelc"
)
WHISPER_REQUIRED_FILES=(
  "config.json"
  "generation_config.json"
)

whisper_ready=true
for d in "${WHISPER_REQUIRED_DIRS[@]}"; do
  if [[ ! -d "${WHISPER_DIR}/${d}" ]]; then
    whisper_ready=false
    break
  fi
  if [[ ! -f "${WHISPER_DIR}/${d}/model.mil" && ! -f "${WHISPER_DIR}/${d}/coremldata.bin" ]]; then
    whisper_ready=false
    break
  fi
done
for f in "${WHISPER_REQUIRED_FILES[@]}"; do
  if [[ ! -f "${WHISPER_DIR}/${f}" ]]; then
    whisper_ready=false
    break
  fi
done

download_whisper_via_git_sparse() {
  local tmp_dir="${STAGING_DIR}/.whisper_sparse_tmp"
  rm -rf "${tmp_dir}"
  echo "  -> Downloading ${WHISPER_VARIANT} from Hugging Face (${HF_REPO}) via sparse git checkout..."
  git clone --depth 1 --filter=blob:none --sparse "https://huggingface.co/${HF_REPO}" "${tmp_dir}"
  (
    cd "${tmp_dir}"
    git sparse-checkout set "${WHISPER_VARIANT}"
    if command -v git-lfs >/dev/null 2>&1; then
      git lfs pull --include="${WHISPER_VARIANT}/**"
    fi
  )
  mkdir -p "${WHISPER_DIR}"
  cp -R "${tmp_dir}/${WHISPER_VARIANT}/." "${WHISPER_DIR}/"
  rm -rf "${tmp_dir}"
}

download_whisper_via_hf_api() {
  echo "  -> Downloading ${WHISPER_VARIANT} files from Hugging Face API (${HF_REPO})..."
  mkdir -p "${WHISPER_DIR}"
  local tree_json
  tree_json="$(curl -sSL --fail "https://huggingface.co/api/models/${HF_REPO}/tree/main/${WHISPER_VARIANT}?recursive=true")"

  local rel_paths
  rel_paths="$(printf '%s' "${tree_json}" | python3 -c '
import json, sys
items = json.load(sys.stdin)
for item in items:
    if item.get("type") == "file":
        p = item.get("path", "")
        prefix = "openai_whisper-small/"
        if p.startswith(prefix):
            print(p[len(prefix):])
')"

  while IFS= read -r rel_path; do
    [[ -z "${rel_path}" ]] && continue
    local target_file="${WHISPER_DIR}/${rel_path}"
    if [[ -f "${target_file}" && -s "${target_file}" ]]; then
      continue
    fi
    mkdir -p "$(dirname "${target_file}")"
    local url="${HF_BASE_URL}/${rel_path}"
    echo "     Fetching ${rel_path}..."
    curl -L --fail --retry 3 -sS -o "${target_file}.part" "${url}"
    mv "${target_file}.part" "${target_file}"
  done <<< "${rel_paths}"
}

if [[ "${whisper_ready}" == "true" ]]; then
  echo "[2/2] Whisper CoreML model already present at ${WHISPER_DIR} — skipping download."
else
  echo "[2/2] Preparing Whisper CoreML model (${WHISPER_VARIANT})..."
  if command -v huggingface-cli >/dev/null 2>&1; then
    echo "  -> Using huggingface-cli to download ${WHISPER_VARIANT}..."
    huggingface-cli download "${HF_REPO}" --include "${WHISPER_VARIANT}/*" --local-dir "${STAGING_DIR}"
  elif command -v hf >/dev/null 2>&1; then
    echo "  -> Using hf CLI to download ${WHISPER_VARIANT}..."
    hf download "${HF_REPO}" --include "${WHISPER_VARIANT}/*" --local-dir "${STAGING_DIR}"
  else
    download_whisper_via_hf_api || download_whisper_via_git_sparse
  fi
fi

# ------------------------------------------------------------------------------
# 3. Verify final folders and sizes
# ------------------------------------------------------------------------------
echo ""
echo "Verifying staged models..."

for f in "${KOKORO_REQUIRED_FILES[@]}"; do
  if [[ ! -s "${KOKORO_DIR}/${f}" ]]; then
    echo "ERROR: Missing required Kokoro file: ${KOKORO_DIR}/${f}" >&2
    exit 1
  fi
done
if [[ ! -d "${KOKORO_DIR}/espeak-ng-data" ]]; then
  echo "ERROR: Missing required Kokoro directory: ${KOKORO_DIR}/espeak-ng-data" >&2
  exit 1
fi

for d in "${WHISPER_REQUIRED_DIRS[@]}"; do
  if [[ ! -d "${WHISPER_DIR}/${d}" ]]; then
    echo "ERROR: Missing required Whisper CoreML bundle: ${WHISPER_DIR}/${d}" >&2
    exit 1
  fi
done
for f in "${WHISPER_REQUIRED_FILES[@]}"; do
  if [[ ! -s "${WHISPER_DIR}/${f}" ]]; then
    echo "ERROR: Missing required Whisper config file: ${WHISPER_DIR}/${f}" >&2
    exit 1
  fi
done

KOKORO_SIZE="$(du -sh "${KOKORO_DIR}" | awk '{print $1}')"
WHISPER_SIZE="$(du -sh "${WHISPER_DIR}" | awk '{print $1}')"

echo "  [OK] ${KOKORO_DIR} (${KOKORO_SIZE})"
echo "  [OK] ${WHISPER_DIR} (${WHISPER_SIZE})"

echo ""
echo "============================================================"
echo "Setup complete! Next manual steps:"
echo "  1. Copy Secrets.example.swift to Vaani/Secrets.swift and fill in your Groq/Gemini API keys:"
echo "       cp Secrets.example.swift Vaani/Secrets.swift"
echo "  2. Open Vaani.xcodeproj in Xcode:"
echo "       open Vaani.xcodeproj"
echo "  3. Add Staging/${WHISPER_VARIANT} to the Vaani target's Copy Bundle Resources"
echo "     as a folder reference (Create folder references), or add an rsync line"
echo "     in the Vaani target's Run Script build phase."
echo "  4. Select your Personal Team in Signing & Capabilities and run on your iOS device."
echo "============================================================"
