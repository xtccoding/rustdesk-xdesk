#!/usr/bin/env bash
# =============================================================================
# xdesk Gitea Actions runner provisioner
# -----------------------------------------------------------------------------
# 目标：在一台干净的 Debian 13 (trixie) LXC 上，把 xdesk APK 的构建环境一次性装齐。
# 特性：
#   * 幂等 —— 每个组件装前先检测，已存在则跳过；可反复执行。
#   * 版本钉死 —— 所有版本号集中在下面 CONFIG 区，跟上游 CI 对齐。
#   * 国内镜像优先 —— Rust/pub/flutter/gradle 全走 USTC / aliyun / flutter-io.cn。
#   * 不依赖 Docker —— runner 跑 host 模式，直接在 LXC 里编译。
#
# 用法（在 runner 节点上，root）：
#   bash ci/provision-runner.sh              # 安装全部
#   bash ci/provision-runner.sh --check      # 只体检，不安装
#   bash ci/provision-runner.sh --profile-only  # 只重写 /etc/profile.d 与镜像配置
#
# 对应节点：runner = 192.168.31.205 (PVE CT 104)
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIG —— 与上游 .github/workflows 保持一致的版本锚点
# ---------------------------------------------------------------------------
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-/opt/android-sdk}"
FLUTTER_ROOT="${FLUTTER_ROOT:-/opt/flutter}"
FLUTTER_VERSION="${FLUTTER_VERSION:-3.24.5}"
JDK_HOME="${JDK_HOME:-/opt/jdk-17}"
JDK_TEMURIN_VER="${JDK_TEMURIN_VER:-17.0.20.1+1}"
JDK_TEMURIN_BUILD="${JDK_TEMURIN_BUILD:-1}"
RUST_VERSION="${RUST_VERSION:-1.75.0}"
RUST_TARGET="${RUST_TARGET:-aarch64-linux-android}"
CARGO_NDK_VERSION="${CARGO_NDK_VERSION:-3.1.2}"
CARGO_EXPAND_VERSION="${CARGO_EXPAND_VERSION:-1.0.95}"
FLUTTER_RUST_BRIDGE_VERSION="${FLUTTER_RUST_BRIDGE_VERSION:-1.80.1}"
VCPKG_ROOT="${VCPKG_ROOT:-/opt/vcpkg}"
VCPKG_COMMIT_ID="${VCPKG_COMMIT_ID:-9e593bb18ea69cc5095e012465dcd675a822ed0d}"
NDK_VERSION="${NDK_VERSION:-28.2.13676358}"
SDK_PLATFORM="${SDK_PLATFORM:-android-36}"
BUILD_TOOLS_VERSION="${BUILD_TOOLS_VERSION:-36.0.0}"
# AGP 8.10.x 的默认 buildToolsVersion 是 35.0.0 —— 即使 app 的 compileSdk 是 36
# 也会被 :app:l8DexDesugarLibRelease 之类的任务拉起来。少装它会在构建时触发
# SDK 自动下载（"Failed to download package!"），必须在 provision 阶段装好。
EXTRA_BUILD_TOOLS="${EXTRA_BUILD_TOOLS:-35.0.0}"
# flutter 插件各自的 compileSdk 会把 android-32/34 之类拉起来。全部预装，
# 免得构建时依赖 AGP 的运行时 SDK 下载（慢且会失败）。
EXTRA_SDK_PLATFORMS="${EXTRA_SDK_PLATFORMS:-android-32 android-33 android-34 android-35}"
SDK_CMAKE_VERSION="${SDK_CMAKE_VERSION:-3.22.1}"
CMDLINE_TOOLS_VERSION="${CMDLINE_TOOLS_VERSION:-13114758}"

# 国内镜像
RUSTUP_DIST_SERVER="${RUSTUP_DIST_SERVER:-https://mirrors.ustc.edu.cn/rust-static}"
RUSTUP_UPDATE_ROOT="${RUSTUP_UPDATE_ROOT:-https://mirrors.ustc.edu.cn/rust-static/rustup}"
PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"
FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"
# Flutter SDK 用官方发布 tarball（国内镜像直连实测 ~4MB/s），比 git clone 整个
# flutter/flutter 仓库（700MB+，还要过代理）快一个数量级。官方 flutter-action 也是这么装的。
FLUTTER_TARBALL_BASE="${FLUTTER_TARBALL_BASE:-https://storage.flutter-io.cn/flutter_infra_release/releases/stable/linux}"
VCPKG_REPO="${VCPKG_REPO:-https://github.com/microsoft/vcpkg.git}"
CRATES_MIRROR="${CRATES_MIRROR:-sparse+https://mirrors.ustc.edu.cn/crates.io-index/}"
ALIYUN_MAVEN="${ALIYUN_MAVEN:-https://maven.aliyun.com/repository/public}"
# apt 源：archive.ubuntu.com / deb.debian.org 实测仅 ~1.6MB/s，清华 tuna 实测 24MB/s。
# 留空则不动系统源。注意 apt 不认 no_proxy，脚本会额外给该镜像写 DIRECT 例外。
APT_MIRROR="${APT_MIRROR:-mirrors.tuna.tsinghua.edu.cn}"

# 可选：境外站点走代理（留空则全直连）。本实验室 CT104 直连 92MB/s，一般留空。
# 注意：GitHub 的 tarball/action 仓库直连会超时，务必配上代理。
export http_proxy="${XDESK_HTTP_PROXY:-}"
export https_proxy="${XDESK_HTTP_PROXY:-}"
# 白名单只放行国内源 + 局域网；dl.google.com 不放行（国内常被墙，让它走代理）
NO_PROXY_LIST="localhost,127.0.0.1,192.168.31.0/24,10.0.0.0/8,.local,mirrors.ustc.edu.cn,mirrors.aliyun.com,maven.aliyun.com,mirror.sjtu.edu.cn,mirrors.tuna.tsinghua.edu.cn,mirrors.cloud.tencent.com,storage.flutter-io.cn,pub.flutter-io.cn"
export no_proxy="$NO_PROXY_LIST"

MODE="${1:-install}"

# --check 模式下，关键组件缺失会置位，最终以非 0 退出，供 CI 决定是否触发安装
CHECK_FAIL=0

log()  { printf '\033[1;36m[provision]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
skip() { printf '\033[1;33m  ↷\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
# 关键缺失：体检模式置位，安装模式直接中止
crit() { printf '\033[1;31m  ✗ %s\033[0m\n' "$*"; CHECK_FAIL=1; }
die()  { printf '\033[1;31m  ✗ %s\033[0m\n' "$*" >&2; exit 1; }

need_root() { [ "$(id -u)" = "0" ] || die "请用 root 运行"; }

# ---------------------------------------------------------------------------
# 0. 基础体检
# ---------------------------------------------------------------------------
check_os() {
  log "0. 系统检查"
  . /etc/os-release
  case "${ID:-}:${VERSION_ID:-}" in
    debian:13|debian:12|ubuntu:24.04|ubuntu:22.04) ok "${PRETTY_NAME}" ;;
    *) warn "未验证的发行版：${PRETTY_NAME:-unknown}（继续，但可能需手工补依赖）" ;;
  esac
  local free_gb
  free_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
  if [ "$free_gb" -lt 40 ]; then
    warn "根分区仅剩 ${free_gb}G，建议 >= 60G（vcpkg + gradle + cargo 缓存很占地方）"
  else
    ok "根分区剩余 ${free_gb}G"
  fi
}

# ---------------------------------------------------------------------------
# 0.5 apt 源换国内镜像
#   Ubuntu 24.04 用 deb822 (/etc/apt/sources.list.d/*.sources)
#   Debian 12/13 可能用经典 sources.list，也可能是 debian.sources —— 两种都覆盖
# ---------------------------------------------------------------------------
apt_mirror() {
  [ -n "$APT_MIRROR" ] || { warn "APT_MIRROR 为空，保留系统默认源"; return; }
  log "0.5 apt 源 -> $APT_MIRROR"
  [ "$MODE" = "check" ] && { ok "跳过（check 模式不改系统源）"; return; }
  local changed=0 f
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.sources; do
    [ -f "$f" ] || continue
    grep -qE 'archive\.ubuntu\.com|security\.ubuntu\.com|ports\.ubuntu\.com|deb\.debian\.org|security\.debian\.org' "$f" || continue
    [ -f "$f.orig" ] || cp "$f" "$f.orig"
    sed -i -E \
      -e "s#https?://[^ ]*archive\.ubuntu\.com/ubuntu#https://$APT_MIRROR/ubuntu#g" \
      -e "s#https?://[^ ]*security\.ubuntu\.com/ubuntu#https://$APT_MIRROR/ubuntu#g" \
      -e "s#https?://[^ ]*ports\.ubuntu\.com/ubuntu-ports#https://$APT_MIRROR/ubuntu-ports#g" \
      -e "s#https?://deb\.debian\.org/debian#https://$APT_MIRROR/debian#g" \
      -e "s#https?://security\.debian\.org/debian-security#https://$APT_MIRROR/debian-security#g" \
      "$f"
    changed=1
  done
  # apt 不读 no_proxy：显式让该镜像直连，否则会被 http_proxy 拖慢（实测 3 倍）
  mkdir -p /etc/apt/apt.conf.d
  {
    echo "// xdesk: 国内镜像直连，避免被 http_proxy 拖慢"
    echo "Acquire::http::Proxy::$APT_MIRROR \"DIRECT\";"
    echo "Acquire::https::Proxy::$APT_MIRROR \"DIRECT\";"
  } > /etc/apt/apt.conf.d/99xdesk-mirror
  [ "$changed" = 1 ] && ok "已切换（原文件备份为 *.orig）" || ok "源已是 $APT_MIRROR"
}

apt_base() {
  log "1. 基础依赖"
  local pkgs="curl wget unzip zip git tar xz-utils ca-certificates pkg-config \
build-essential cmake ninja-build python3 python3-pip perl autoconf automake \
libtool bison flex pkgconf zip file gettext libssl-dev libtool-bin nasm yasm \
clang llvm lld zlib1g-dev p7zip-full nodejs npm"
  # 编译 vcpkg 依赖必需的可执行文件
  local crit_bins="gcc g++ make cmake ninja pkg-config python3 perl autoconf automake libtool bison flex nasm git curl unzip node"
  if [ "$MODE" = "check" ]; then
    local miss=""
    for p in $pkgs; do dpkg -s "$p" >/dev/null 2>&1 || miss="$miss $p"; done
    local cmiss=""
    for b in $crit_bins; do command -v "$b" >/dev/null 2>&1 || cmiss="$cmiss $b"; done
    [ -z "$cmiss" ] && ok "编译工具链齐全" || crit "缺失可执行文件:$cmiss"
    [ -z "$miss" ] && ok "apt 包齐全" || warn "非关键 apt 包缺失:$miss"
    return
  fi
  apt_mirror
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  # nodejs 用 nodesource 太折腾，Debian 13 自带 v20 够用
  apt-get install -y -qq $pkgs >/dev/null
  ok "基础依赖已安装"
  # Actions 的 Node 步骤要求 PATH 里能直接找到 node
  [ -x /usr/bin/nodejs ] && [ ! -e /usr/local/bin/node ] && ln -sf /usr/bin/nodejs /usr/local/bin/node
  ok "node -> $(node --version 2>/dev/null || echo '未就绪')"
}

# ---------------------------------------------------------------------------
# 2. JDK 17（Debian 13 已移除 openjdk-17，必须用 Temurin tarball）
# ---------------------------------------------------------------------------
install_jdk() {
  log "2. JDK 17 (Temurin)"
  if [ -x "$JDK_HOME/bin/java" ]; then
    skip "已存在：$("$JDK_HOME/bin/java" -version 2>&1 | head -1)"
  else
    [ "$MODE" = "check" ] && { crit "缺失 $JDK_HOME"; return; }
    local url="https://github.com/adoptium/temurin17-binaries/releases/download/jdk-${JDK_TEMURIN_VER//+/%2B}/OpenJDK17U-jdk_x64_linux_hotspot_${JDK_TEMURIN_VER//+/_}.tar.gz"
    mkdir -p /opt
    log "  下载 $url"
    curl -fL --retry 3 -o /tmp/jdk17.tar.gz "$url"
    mkdir -p "$JDK_HOME"
    tar -xzf /tmp/jdk17.tar.gz -C "$JDK_HOME" --strip-components=1
    rm -f /tmp/jdk17.tar.gz
    ok "$("$JDK_HOME/bin/java" -version 2>&1 | head -1)"
  fi
  # 关键：sdkmanager(第3步) 与 gradle 都要 JAVA_HOME，而本脚本是以非登录 shell
  # 运行的，不能指望 /etc/profile.d/xdesk-build.sh —— 那是第 8 步才写出来的。
  # 漏了这两行，sdkmanager 会报 "Please set the JAVA_HOME variable" 然后退出 1。
  export JAVA_HOME="$JDK_HOME"
  export PATH="$JDK_HOME/bin:$PATH"
}

# ---------------------------------------------------------------------------
# 3. Android SDK + NDK
# ---------------------------------------------------------------------------
install_android_sdk() {
  log "3. Android SDK / NDK $NDK_VERSION"
  # 保险：万一 install_jdk 走了 check 分支提前 return 没导出 JAVA_HOME
  export JAVA_HOME="${JAVA_HOME:-$JDK_HOME}"
  export PATH="$JAVA_HOME/bin:$PATH"
  local sdkmanager="$ANDROID_SDK_ROOT/cmdline-tools/latest/bin/sdkmanager"
  if [ "$MODE" != "check" ] && [ ! -x "$sdkmanager" ]; then
    mkdir -p "$ANDROID_SDK_ROOT/cmdline-tools"
    local url="https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS_VERSION}_latest.zip"
    log "  下载 cmdline-tools $CMDLINE_TOOLS_VERSION"
    curl -fL --retry 3 -o /tmp/cmdtools.zip "$url"
    rm -rf /tmp/cmdtools && mkdir -p /tmp/cmdtools
    unzip -q /tmp/cmdtools.zip -d /tmp/cmdtools
    rm -rf "$ANDROID_SDK_ROOT/cmdline-tools/latest"
    mv /tmp/cmdtools/cmdline-tools "$ANDROID_SDK_ROOT/cmdline-tools/latest"
    rm -rf /tmp/cmdtools /tmp/cmdtools.zip
    ok "cmdline-tools 就位"
  fi
  if [ -x "$sdkmanager" ]; then ok "sdkmanager 已存在"; else crit "sdkmanager 缺失"; fi

  if [ "$MODE" = "check" ]; then
    for d in "platforms/$SDK_PLATFORM" $EXTRA_SDK_PLATFORMS \
             "build-tools/$BUILD_TOOLS_VERSION" "build-tools/$EXTRA_BUILD_TOOLS" \
             "cmake/$SDK_CMAKE_VERSION" "ndk/$NDK_VERSION" platform-tools; do
      if [ -d "$ANDROID_SDK_ROOT/$d" ]; then ok "$d"; else crit "缺 $d"; fi
    done
    return
  fi

  export ANDROID_SDK_ROOT
  local pkgs="platform-tools platforms;$SDK_PLATFORM build-tools;$BUILD_TOOLS_VERSION \
build-tools;$EXTRA_BUILD_TOOLS cmake;$SDK_CMAKE_VERSION ndk;$NDK_VERSION"
  for p in $EXTRA_SDK_PLATFORMS; do pkgs="$pkgs platforms;$p"; done
  yes | "$sdkmanager" --licenses >/dev/null 2>&1 || true
  # shellcheck disable=SC2086
  "$sdkmanager" --install $pkgs 2>&1 | tail -3
  ok "SDK 组件安装完成"
}

# ---------------------------------------------------------------------------
# 4. Rust 1.75 + android target
# ---------------------------------------------------------------------------
install_rust() {
  log "4. Rust $RUST_VERSION + $RUST_TARGET"
  export CARGO_HOME="${CARGO_HOME:-/root/.cargo}"
  export RUSTUP_HOME="${RUSTUP_HOME:-/root/.rustup}"
  export RUSTUP_DIST_SERVER RUSTUP_UPDATE_ROOT
  if [ ! -x "$CARGO_HOME/bin/rustup" ]; then
    [ "$MODE" = "check" ] && { crit "rustup 未安装"; return; }
    log "  安装 rustup（USTC 镜像）"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --default-toolchain "$RUST_VERSION" --profile minimal --no-modify-path
  else
    skip "rustup 已存在"
  fi
  if [ "$MODE" = "check" ]; then
    ok "$("$CARGO_HOME/bin/rustc" --version 2>/dev/null)"
    if "$CARGO_HOME/bin/rustup" component list --toolchain "$RUST_VERSION" 2>/dev/null | grep -q '^rustfmt.*installed'; then ok "rustfmt"; else crit "缺 rustfmt"; fi
    return
  fi

  # 确保 toolchain 版本正确
  if ! "$CARGO_HOME/bin/rustup" toolchain list 2>/dev/null | grep -q "^${RUST_VERSION}-"; then
    "$CARGO_HOME/bin/rustup" toolchain install "$RUST_VERSION" --profile minimal
  fi
  "$CARGO_HOME/bin/rustup" default "$RUST_VERSION" >/dev/null
  # 只在缺失时加 target —— 反复 add 会触发 manifest 重同步，有损坏 toolchain 的风险
  if ! "$CARGO_HOME/bin/rustup" target list --installed 2>/dev/null | grep -qx "$RUST_TARGET"; then
    "$CARGO_HOME/bin/rustup" target add "$RUST_TARGET"
  fi
  if ! "$CARGO_HOME/bin/rustup" component list --toolchain "$RUST_VERSION" 2>/dev/null | grep -q '^rustfmt.*installed'; then
    "$CARGO_HOME/bin/rustup" component add rustfmt --toolchain "$RUST_VERSION"
  fi
  ok "$("$CARGO_HOME/bin/rustc" --version)  targets: $("$CARGO_HOME/bin/rustup" target list --installed | tr '\n' ' ')"
}

install_cargo_tools() {
  log "5. cargo-ndk $CARGO_NDK_VERSION / cargo-expand / flutter_rust_bridge_codegen"
  export CARGO_HOME="${CARGO_HOME:-/root/.cargo}"
  export PATH="$CARGO_HOME/bin:$PATH"
  if [ "$MODE" = "check" ]; then
    if command -v cargo-ndk >/dev/null; then ok "cargo-ndk $(cargo ndk --version 2>&1)"; else crit "缺 cargo-ndk"; fi
    if command -v flutter_rust_bridge_codegen >/dev/null; then ok "frb_codegen"; else crit "缺 frb_codegen"; fi
    return
  fi
  command -v cargo-ndk >/dev/null || cargo install cargo-ndk --version "$CARGO_NDK_VERSION" --locked
  # codegen 需要 cargo-expand
  command -v cargo-expand >/dev/null || cargo install cargo-expand --version "$CARGO_EXPAND_VERSION" --locked
  command -v flutter_rust_bridge_codegen >/dev/null || \
    cargo install flutter_rust_bridge_codegen --version "$FLUTTER_RUST_BRIDGE_VERSION" --features uuid --locked
  ok "cargo 工具链就绪"
}

# ---------------------------------------------------------------------------
# 6. Flutter
# ---------------------------------------------------------------------------
install_flutter() {
  log "6. Flutter $FLUTTER_VERSION"
  if [ -x "$FLUTTER_ROOT/bin/flutter" ] && [ -f "$FLUTTER_ROOT/version" ] \
     && [ "$(cat "$FLUTTER_ROOT/version")" = "$FLUTTER_VERSION" ]; then
    ok "已存在 $(cat "$FLUTTER_ROOT/version")"
    return
  fi
  [ "$MODE" = "check" ] && { crit "Flutter 缺失或版本不符"; return; }
  export FLUTTER_STORAGE_BASE_URL PUB_HOSTED_URL
  if [ -d "$FLUTTER_ROOT/.git" ]; then
    # 已有 git 检出：就地切版本，不用重下 700MB
    git -C "$FLUTTER_ROOT" fetch --depth 1 origin "$FLUTTER_VERSION"
    git -C "$FLUTTER_ROOT" checkout -f "$FLUTTER_VERSION"
    git config --global --add safe.directory "$FLUTTER_ROOT"
  else
    # 全新安装：拉官方发布 tarball 解压。注意解出来没有 .git —— 没关系，
    # `git apply` 在非仓库目录同样可用（官方 flutter-action 也是这么装的，
    # 它装完照样在 .github/workflows 里跑 `git apply` 打补丁）。
    local url="$FLUTTER_TARBALL_BASE/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
    log "  下载 $url"
    curl -fL --retry 3 -o /tmp/flutter.tar.xz "$url"
    rm -rf /tmp/flutter-extract && mkdir -p /tmp/flutter-extract
    tar -xJf /tmp/flutter.tar.xz -C /tmp/flutter-extract
    rm -rf "$FLUTTER_ROOT"
    mv /tmp/flutter-extract/flutter "$FLUTTER_ROOT"
    rm -rf /tmp/flutter-extract /tmp/flutter.tar.xz
  fi
  "$FLUTTER_ROOT/bin/flutter" --version
  ok "Flutter $FLUTTER_VERSION"
}

# ---------------------------------------------------------------------------
# 7. vcpkg @ 钉死 commit + bootstrap
# ---------------------------------------------------------------------------
install_vcpkg() {
  log "7. vcpkg @ $VCPKG_COMMIT_ID"
  if [ -d "$VCPKG_ROOT/.git" ]; then
    local cur; cur="$(git -C "$VCPKG_ROOT" rev-parse HEAD 2>/dev/null || echo '')"
    if [ "$cur" != "$VCPKG_COMMIT_ID" ]; then
      [ "$MODE" = "check" ] && { crit "vcpkg commit 不符：$cur"; return; }
      git -C "$VCPKG_ROOT" fetch --all --tags -q
      git -C "$VCPKG_ROOT" checkout -f "$VCPKG_COMMIT_ID"
    else
      skip "已在目标 commit"
    fi
  else
    [ "$MODE" = "check" ] && { crit "vcpkg 未安装"; return; }
    # 按 SHA 浅取：全量 clone vcpkg 要 200MB+，而这里只要那一个 commit 的树
    mkdir -p "$VCPKG_ROOT"
    git -C "$VCPKG_ROOT" init -q
    if git -C "$VCPKG_ROOT" remote get-url origin >/dev/null 2>&1; then
      git -C "$VCPKG_ROOT" remote set-url origin "$VCPKG_REPO"
    else
      git -C "$VCPKG_ROOT" remote add origin "$VCPKG_REPO"
    fi
    git -C "$VCPKG_ROOT" fetch --depth 1 origin "$VCPKG_COMMIT_ID"
    git -C "$VCPKG_ROOT" checkout -q -f FETCH_HEAD
  fi
  if [ ! -x "$VCPKG_ROOT/vcpkg" ] && [ "$MODE" != "check" ]; then
    "$VCPKG_ROOT/bootstrap-vcpkg.sh" -disableMetrics
  fi
  ok "vcpkg 就位（$(git -C "$VCPKG_ROOT" rev-parse --short HEAD)）"
}

# ---------------------------------------------------------------------------
# 8. 构建环境 profile + 镜像配置（--profile-only 时只跑这一步）
# ---------------------------------------------------------------------------
write_profile() {
  log "8. 写 /etc/profile.d/xdesk-build.sh 与镜像配置"

  # 代理 → gradle systemProp（比 JAVA_TOOL_OPTIONS 干净，不污染 java 输出）
  local GRADLE_PROXY=""
  if [ -n "${XDESK_HTTP_PROXY:-}" ]; then
    local ph pp
    ph="${XDESK_HTTP_PROXY#*://}"; ph="${ph%%:*}"
    pp="${XDESK_HTTP_PROXY##*:}"; pp="${pp%%/*}"
    GRADLE_PROXY="systemProp.http.proxyHost=$ph
systemProp.http.proxyPort=$pp
systemProp.https.proxyHost=$ph
systemProp.https.proxyPort=$pp
systemProp.http.nonProxyHosts=$(printf '%s' "$NO_PROXY_LIST" | tr ',' '|')"
    ok "gradle 代理 -> $ph:$pp"
  fi

  cat > /etc/profile.d/xdesk-build.sh <<EOF
# ===== xdesk build environment (generated by ci/provision-runner.sh) =====
export ANDROID_HOME=$ANDROID_SDK_ROOT
export ANDROID_SDK_ROOT=$ANDROID_SDK_ROOT
export ANDROID_NDK_HOME=$ANDROID_SDK_ROOT/ndk/$NDK_VERSION
export VCPKG_ROOT=$VCPKG_ROOT
export JAVA_HOME=$JDK_HOME
export CARGO_HOME=/root/.cargo
export RUSTUP_HOME=/root/.rustup
export GRADLE_USER_HOME=/root/.gradle
export PUB_CACHE=/root/.pub-cache
export PATH=/root/.cargo/bin:$FLUTTER_ROOT/bin:$JDK_HOME/bin:\$ANDROID_HOME/cmdline-tools/latest/bin:\$ANDROID_HOME/platform-tools:\$ANDROID_HOME/cmake/$SDK_CMAKE_VERSION/bin:\$PATH
# 6GB runner 保守并发：避免 vcpkg/Gradle 同时把容器推入 swap。
export CMAKE_BUILD_PARALLEL_LEVEL=2
export VCPKG_MAX_CONCURRENCY=2
export CARGO_BUILD_JOBS=2
# ---- 非特权 LXC 关键修复 ----
# LXC 里 root 解压 tar 时，tar 会尝试 chown 成归档内的 uid/gid；非特权容器的
# uid 映射覆盖不到（如 397546:5000），chown 返回 EINVAL，tar 直接 exit 2。
# Flutter 内部用 tar 解压 gradle-wrapper，一旦失败会连带 flutter pub get 全挂。
# 让 tar 永远不要还原属主，是这个问题最干净的全局解法。
export TAR_OPTIONS="--no-same-owner"
# ---- 代理（默认关闭；如需境外加速设 XDESK_HTTP_PROXY） ----
${XDESK_HTTP_PROXY:+export http_proxy=$XDESK_HTTP_PROXY
export https_proxy=$XDESK_HTTP_PROXY}
export no_proxy=$NO_PROXY_LIST
# ---- 国内镜像 ----
export RUSTUP_DIST_SERVER=$RUSTUP_DIST_SERVER
export RUSTUP_UPDATE_ROOT=$RUSTUP_UPDATE_ROOT
export PUB_HOSTED_URL=$PUB_HOSTED_URL
export FLUTTER_STORAGE_BASE_URL=$FLUTTER_STORAGE_BASE_URL
EOF
  chmod 0644 /etc/profile.d/xdesk-build.sh
  ok "/etc/profile.d/xdesk-build.sh"

  # ---- cargo 镜像 ----
  mkdir -p /root/.cargo
  cat > /root/.cargo/config.toml <<EOF
[source.crates-io]
replace-with = "ustc"

[source.ustc]
registry = "$CRATES_MIRROR"

[net]
git-fetch-with-cli = true
EOF
  ok "/root/.cargo/config.toml"

  # ---- gradle 镜像 ----
  mkdir -p /root/.gradle
  cat > /root/.gradle/init.gradle <<EOF
// 阿里云 maven 镜像优先，官方作为兜底。
//
// ⚠️ 只镜像 settings 级的 pluginManagement 仓库，绝对不要往 project 加仓库。
//    Flutter 的 settings.gradle 里有 includeBuild("\$flutterSdkPath/packages/flutter_tools/gradle")，
//    那个 :gradle 子构建声明了 repositoriesMode = PREFER_SETTINGS。任何往 project
//    加仓库的写法（allprojects / beforeProject）都会命中它，直接报：
//      Build was configured to prefer settings repositories over project repositories
//      but repository 'maven' was added by settings file 'settings.gradle'
//    实测：allprojects → 失败；beforeProject → 失败；仅 beforeSettings → 通过。
//
// 另外必须用 beforeSettings 而非 settingsEvaluated：后者跑在 settings.gradle 之后，
// aliyun 会被排到 google()/mavenCentral() 后面，等于白配。
def ALIYUN        = '$ALIYUN_MAVEN'
def ALIYUN_GOOGLE = 'https://maven.aliyun.com/repository/google'
def ALIYUN_PLUGIN = 'https://maven.aliyun.com/repository/gradle-plugin'

beforeSettings { settings ->
    settings.pluginManagement {
        repositories {
            maven { url ALIYUN_PLUGIN }
            maven { url ALIYUN_GOOGLE }
            maven { url ALIYUN }
            gradlePluginPortal()
            google()
            mavenCentral()
        }
    }
}
EOF
  ok "/root/.gradle/init.gradle"

  cat > /root/.gradle/gradle.properties <<EOF
org.gradle.jvmargs=-Xmx2g -XX:MaxMetaspaceSize=512m -Dfile.encoding=UTF-8
org.gradle.daemon=false
org.gradle.parallel=false
org.gradle.workers.max=2
kotlin.compiler.execution.strategy=in-process
android.useAndroidX=true
android.enableJetifier=false
${GRADLE_PROXY}
EOF
  ok "/root/.gradle/gradle.properties"

  # ---- Flutter 关掉 analytics，免得污染日志 ----
  export HOME=/root
  [ -x "$FLUTTER_ROOT/bin/flutter" ] && "$FLUTTER_ROOT/bin/flutter" config --no-analytics >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# 9. 体检汇总
# ---------------------------------------------------------------------------
summary() {
  log "9. 环境体检"
  source /etc/profile.d/xdesk-build.sh 2>/dev/null || true
  export HOME=/root
  printf '  %-22s %s\n' "flutter"      "$(flutter --version 2>/dev/null | head -1 || echo '✗')"
  printf '  %-22s %s\n' "dart"         "$([ -x "$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart" ] && "$FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart" --version 2>&1 | head -1 || echo '✗')"
  printf '  %-22s %s\n' "java"         "$(java -version 2>&1 | grep -v JAVA_TOOL | head -1 || echo '✗')"
  printf '  %-22s %s\n' "rustc"        "$(rustc --version 2>/dev/null || echo '✗')"
  printf '  %-22s %s\n' "rust targets" "$(rustup target list --installed 2>/dev/null | tr '\n' ' ' || echo '✗')"
  printf '  %-22s %s\n' "cargo-ndk"    "$(cargo ndk --version 2>&1 || echo '✗')"
  printf '  %-22s %s\n' "frb_codegen"  "$(flutter_rust_bridge_codegen --version 2>&1 | head -1 || echo '✗')"
  printf '  %-22s %s\n' "node"         "$(node --version 2>/dev/null || echo '✗')"
  printf '  %-22s %s\n' "NDK"          "$([ -d "$ANDROID_NDK_HOME" ] && echo "$ANDROID_NDK_HOME" || echo '✗')"
  printf '  %-22s %s\n' "vcpkg"        "$(git -C "$VCPKG_ROOT" rev-parse --short HEAD 2>/dev/null || echo '✗')"
  printf '  %-22s %s\n' "disk free"    "$(df -h / | tail -1 | awk '{print $4}')"
}

# ---------------------------------------------------------------------------
main() {
  need_root
  case "$MODE" in
    --check|check)        MODE=check ;;
    --profile-only)       MODE=profile ;;
    install|"")           MODE=install ;;
    -h|--help)            sed -n '2,20p' "$0"; exit 0 ;;
    *) die "未知参数：$MODE（用 --check / --profile-only / 无参数）" ;;
  esac

  check_os
  if [ "$MODE" = "profile" ]; then write_profile; summary; exit 0; fi
  apt_base
  install_jdk
  # 镜像 / 代理配置必须早于所有联网安装步骤：
  #   * install_cargo_tools 要读 /root/.cargo/config.toml 里的 USTC crates 镜像，
  #     否则全程裸连 crates.io —— frb_codegen 依赖树极大，会慢到离谱。
  #   * 后续步骤要 http_proxy / TAR_OPTIONS 等。
  # 原实现把 write_profile 放在最后，等于这些配置对前面的安装步骤全部无效。
  [ "$MODE" != "check" ] && write_profile
  install_android_sdk
  install_rust
  install_cargo_tools
  install_flutter
  install_vcpkg
  summary
  if [ "$MODE" = "check" ] && [ "$CHECK_FAIL" != "0" ]; then
    die "体检未通过：关键组件缺失（不带参数运行本脚本可自动安装）"
  fi
  log "完成。新 shell 会自动 source /etc/profile.d/xdesk-build.sh"
}

main "$@"
