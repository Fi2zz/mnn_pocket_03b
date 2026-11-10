#!/usr/bin/env bash
# Provision MNN-Pocket models to a connected Android device.
#
# Usage:
#   tools/provision_device.sh [--serial SERIAL] [--install]
#
# What it pushes:
#   LLM  : _sources/MNN-Pocket-0.3B-MNN/{config.json,llm.mnn,llm.mnn.weight,
#          llm_config.json,tokenizer.mtok} -> app_flutter/models/MNN-Pocket-0.3B-MNN/
#   ASR  : INT8 encoder/decoder/joiner + tokens.txt     -> files/asr/
#   VAD  : silero_vad.onnx                              -> files/asr/
#
# Requirements:
#   - adb in PATH and a device connected (USB debugging enabled)
#   - the app installed as a DEBUG build (so `run-as` works)
#   - model files present under _sources/ (see _sources/README or the
#     MNN-Pocket ModelScope page)
#
# Examples:
#   tools/provision_device.sh                 # default device
#   tools/provision_device.sh --install       # install the latest debug APK first
#   tools/provision_device.sh --serial 23124RN87C
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ID="com.example.mnn"
SERIAL=""
INSTALL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial)
      SERIAL="${2:?--serial needs a value}"
      shift 2
      ;;
    --install)
      INSTALL=1
      shift
      ;;
    -h|--help)
      sed -n '2,24p' "$0"
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

ADB=(adb)
if [[ -n "$SERIAL" ]]; then
  ADB+=(-s "$SERIAL")
fi

"${ADB[@]}" get-state >/dev/null 2>&1 || {
  echo "no device found (check: adb devices)" >&2
  exit 1
}

MODEL="$("${ADB[@]}" shell getprop ro.product.model | tr -d '\r')"
PLATFORM="$("${ADB[@]}" shell getprop ro.board.platform | tr -d '\r')"
echo "device: ${MODEL:-unknown} / ${PLATFORM:-unknown}"

APK="$ROOT/build/app/outputs/flutter-apk/app-debug.apk"
if [[ "$INSTALL" -eq 1 ]]; then
  if [[ ! -f "$APK" ]]; then
    echo "APK not found: $APK" >&2
    echo "build it first: flutter build apk --debug" >&2
    exit 1
  fi
  "${ADB[@]}" install -r -t "$APK"
fi

if ! "${ADB[@]}" shell pm list packages | grep -q "package:${APP_ID}"; then
  echo "app not installed: ${APP_ID}" >&2
  echo "rerun with --install (or: adb install -r -t $APK)" >&2
  exit 1
fi

if ! "${ADB[@]}" shell run-as "$APP_ID" id >/dev/null 2>&1; then
  echo "run-as failed: ${APP_ID} is not debuggable" >&2
  echo "this script expects the debug APK; a release build cannot be provisioned this way" >&2
  exit 1
fi

MODEL_DIR="$ROOT/_sources/MNN-Pocket-0.3B-MNN"
MODEL_FILES=(
  "config.json"
  "llm.mnn"
  "llm.mnn.weight"
  "llm_config.json"
  "tokenizer.mtok"
)
ASR_FILES=(
  "$ROOT/_sources/xasr/encoder-480ms.int8.onnx"
  "$ROOT/_sources/xasr/decoder-480ms.int8.onnx"
  "$ROOT/_sources/xasr/joiner-480ms.int8.onnx"
  "$ROOT/_sources/xasr/tokens.txt"
  "$ROOT/_sources/asr/silero_vad.onnx"
)

for f in "${MODEL_FILES[@]}"; do
  if [[ ! -f "$MODEL_DIR/$f" ]]; then
    echo "missing model file: $MODEL_DIR/$f" >&2
    exit 1
  fi
done
for f in "${ASR_FILES[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "missing model file: $f" >&2
    exit 1
  fi
done

echo "stopping app..."
"${ADB[@]}" shell am force-stop "$APP_ID" >/dev/null 2>&1 || true

"${ADB[@]}" shell run-as "$APP_ID" mkdir -p \
  app_flutter/models/MNN-Pocket-0.3B-MNN files/asr

push_file() {
  local src="$1"
  local dest_dir="$2"
  local name
  name="$(basename "$src")"
  echo "pushing ${name} ($(du -h "$src" | cut -f1))..."
  "${ADB[@]}" push "$src" "/data/local/tmp/${name}" >/dev/null
  "${ADB[@]}" shell "run-as ${APP_ID} cp /data/local/tmp/${name} ${dest_dir}/${name}"
  "${ADB[@]}" shell "rm -f /data/local/tmp/${name}" >/dev/null 2>&1 || true
}

for f in "${MODEL_FILES[@]}"; do
  push_file "$MODEL_DIR/$f" app_flutter/models/MNN-Pocket-0.3B-MNN
done
for f in "${ASR_FILES[@]}"; do
  push_file "$f" files/asr
done

echo
echo "done:"
"${ADB[@]}" shell run-as "$APP_ID" ls -lh \
  app_flutter/models/MNN-Pocket-0.3B-MNN files/asr
echo
echo "relaunch the app to load the new weights."
