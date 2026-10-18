#!/usr/bin/env bash
# =============================================================================
# CI 专用：构建 Android 需要的 librustdesk.so
# -----------------------------------------------------------------------------
# 上游 flutter/ndk_arm64.sh 保持原样（便于跟 upstream rebase），本脚本是 CI 侧
# 的等价替代，只做两处必需改动：
#
# 1) --bindgen
#    hwcodec 的 build.rs 用 bindgen 解析 cpp/common/*.h。cargo-ndk 默认**不**
#    设置 BINDGEN_EXTRA_CLANG_ARGS_<target>，于是 libclang 拿不到 Android
#    sysroot，回退到宿主头文件后报：
#      /usr/include/stdint.h:26:10: fatal error:
#      'bits/libc-header-start.h' file not found
#    （sysroot 的自动解析是 clang **驱动**的行为，libclang 这个库没有，
#      所以把 LIBCLANG_PATH 指向 NDK 自带的 libclang 也救不回来。）
#
# 2) --lib
#    Cargo.toml: [lib] name="librustdesk" crate-type=["cdylib","staticlib","rlib"]
#    APK 只需要 liblibrustdesk.so。上游脚本会连带编译 rustdesk / service /
#    naming 三个二进制，而 [profile.release] 是 lto=true + codegen-units=1
#    （fat LTO），每个二进制链接峰值 2GB+ 内存。6GB 的 runner 会被压到 swap
#    抖动、sshd 都失去响应。只编 lib 既绕开内存墙，又省约 20 分钟。
#
# 用法：./ci/build-android-lib.sh [target] [api-level]
# =============================================================================
set -euo pipefail

: "${ANDROID_NDK_HOME:?请先 source /etc/profile.d/xdesk-build.sh}"

TARGET="${1:-aarch64-linux-android}"
PLATFORM="${2:-21}"

echo "==> cargo ndk build --lib  target=$TARGET  api=$PLATFORM"
echo "    NDK=$ANDROID_NDK_HOME"
echo "    cargo-ndk=$(cargo ndk --version 2>&1)"

cargo ndk \
  --platform "$PLATFORM" \
  --target "$TARGET" \
  --bindgen \
  build --lib --locked --release --features flutter,hwcodec

SO="target/${TARGET}/release/liblibrustdesk.so"
if [ ! -f "$SO" ]; then
  echo "ERROR: 未产出 $SO" >&2
  exit 1
fi
ls -lh "$SO"
