#!/usr/bin/env bash
# Build the MNN runtime + LLM engine as an Android arm64 shared library and
# vendor it into the Flutter plugin.
#
# The resulting libMNN.so contains both the MNN runtime and the LLM engine
# (MNN_SEP_BUILD=OFF, MNN_BUILD_SHARED_LIBS=ON). libc++_shared.so from the
# NDK is copied alongside it because both the bridge and libMNN.so are built
# with c++_shared.
#
# Requirements:
#   - git, cmake, ninja (recommended)
#   - Android NDK 28.2.13676358, or set ANDROID_NDK_HOME
#   - network access on the first run (shallow clone of MNN)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MNN_COMMIT="b0239771b07b317a258fbc384683bbd540741406"
NDK="${ANDROID_NDK_HOME:-${ANDROID_HOME:-$HOME/Library/Android/sdk}/ndk/28.2.13676358}"
MNN_SRC="$ROOT/_sources/MNN"
BUILD_DIR="$ROOT/_sources/mnn-build-android-shared"
PLUGIN_DIR="$ROOT/third_party/mnn_local_llm/android"
JNI_DIR="$PLUGIN_DIR/src/main/jniLibs/arm64-v8a"
INCLUDE_DIR="$PLUGIN_DIR/src/main/cpp/mnn/include"

if [[ ! -d "$NDK" ]]; then
  echo "Android NDK not found: $NDK" >&2
  echo "set ANDROID_NDK_HOME or ANDROID_HOME" >&2
  exit 1
fi

case "$(uname -s)" in
  Darwin) LLVM_HOST="darwin-x86_64" ;;
  Linux)  LLVM_HOST="linux-x86_64" ;;
  *) echo "unsupported host: $(uname -s)" >&2; exit 1 ;;
esac

TOOLCHAIN="$NDK/build/cmake/android.toolchain.cmake"
LLVM_BIN="$NDK/toolchains/llvm/prebuilt/$LLVM_HOST/bin"
STRIP="$LLVM_BIN/llvm-strip"

if [[ ! -x "$STRIP" ]]; then
  echo "llvm-strip not found: $STRIP" >&2
  exit 1
fi

mkdir -p "$ROOT/_sources"

# ---------------------------------------------------------------------------
# MNN source at the pinned commit
# ---------------------------------------------------------------------------
if [[ ! -d "$MNN_SRC/.git" ]]; then
  echo "cloning MNN..."
  git clone --filter=blob:none --no-checkout https://github.com/alibaba/MNN.git "$MNN_SRC"
fi

current="$(git -C "$MNN_SRC" rev-parse HEAD 2>/dev/null || true)"
if [[ "$current" != "$MNN_COMMIT" ]]; then
  echo "checking out MNN $MNN_COMMIT..."
  git -C "$MNN_SRC" fetch --depth 1 origin "$MNN_COMMIT"
  git -C "$MNN_SRC" checkout --detach "$MNN_COMMIT"
fi

# ---------------------------------------------------------------------------
# Configure and build
# ---------------------------------------------------------------------------
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
GENERATOR=()
if command -v ninja >/dev/null 2>&1; then
  GENERATOR=(-G Ninja)
fi

cmake -S "$MNN_SRC" -B "$BUILD_DIR" "${GENERATOR[@]}" \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
  -DCMAKE_BUILD_TYPE=Release \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_STL=c++_shared \
  -DANDROID_PLATFORM=android-21 \
  -DMNN_BUILD_LLM=ON \
  -DMNN_LLM_BUILD_DEMO=OFF \
  -DMNN_LOW_MEMORY=ON \
  -DMNN_SUPPORT_TRANSFORMER_FUSE=ON \
  -DMNN_BUILD_SHARED_LIBS=ON \
  -DMNN_SEP_BUILD=OFF \
  -DMNN_BUILD_OPENCV=OFF \
  -DMNN_BUILD_DIFFUSION=OFF \
  -DMNN_BUILD_BENCHMARK=OFF \
  -DMNN_BUILD_TEST=OFF \
  -DMNN_BUILD_TOOLS=OFF \
  -DMNN_BUILD_FOR_ANDROID_COMMAND=true \
  -DMNN_USE_LOGCAT=OFF \
  -DMNN_USE_SSE=OFF

cmake --build "$BUILD_DIR" --target MNN -j "$JOBS"

# ---------------------------------------------------------------------------
# Vendor stripped libraries
# ---------------------------------------------------------------------------
mkdir -p "$JNI_DIR"

cp "$BUILD_DIR/libMNN.so" "$JNI_DIR/libMNN.so"
cp "$NDK/toolchains/llvm/prebuilt/$LLVM_HOST/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" \
  "$JNI_DIR/libc++_shared.so"
"$STRIP" --strip-unneeded "$JNI_DIR/libMNN.so"
"$STRIP" --strip-unneeded "$JNI_DIR/libc++_shared.so"

# ---------------------------------------------------------------------------
# Vendor headers (MNN + LLM engine)
# ---------------------------------------------------------------------------
rm -rf "$INCLUDE_DIR"
mkdir -p "$INCLUDE_DIR"
cp -R "$MNN_SRC/include/MNN" "$INCLUDE_DIR/"
cp -R "$MNN_SRC/transformers/llm/engine/include/llm" "$INCLUDE_DIR/"

echo "libMNN.so        -> $JNI_DIR/libMNN.so"
echo "libc++_shared.so -> $JNI_DIR/libc++_shared.so"
echo "headers          -> $INCLUDE_DIR"
