# ci/

xdesk 的构建环境与 CI 定义。

## `provision-runner.sh`

把一台干净的 Debian 13 LXC 变成 xdesk APK 构建机。**幂等**，可反复执行。

```bash
bash ci/provision-runner.sh              # 安装全部（已存在的组件自动跳过）
bash ci/provision-runner.sh --check      # 只体检；关键组件缺失时退出码非 0
bash ci/provision-runner.sh --profile-only   # 只重写 /etc/profile.d 与镜像配置
```

`--check` 的退出码设计成可被 CI 直接消费：

```bash
if ! bash ci/provision-runner.sh --check; then
  bash ci/provision-runner.sh          # 缺什么装什么
fi
```

### 装了什么

| 组件 | 版本 | 位置 |
|---|---|---|
| Flutter | 3.24.5（含 Dart 3.5.4） | `/opt/flutter` |
| JDK | Temurin 17.0.20.1 | `/opt/jdk-17` |
| Android SDK | platform 36 / build-tools 36.0.0 / cmake 3.22.1 | `/opt/android-sdk` |
| NDK | 28.2.13676358 | `/opt/android-sdk/ndk/` |
| Rust | 1.75.0 + `aarch64-linux-android` | `/root/.cargo` |
| cargo-ndk | 3.1.2 | `~/.cargo/bin` |
| flutter_rust_bridge_codegen | 1.80.1 | `~/.cargo/bin` |
| vcpkg | 钉在 `9e593bb18ea69cc5095e012465dcd675a822ed0d` | `/opt/vcpkg` |

版本锚点全部集中在脚本顶部 CONFIG 区，与 `.gitea/workflows/build-xdesk.yml` 的 `env:` 对应。

### 国内镜像

境外站点直连会超时（实测 GitHub tarball 25s 下不完），所以**默认要配代理**：

```bash
XDESK_HTTP_PROXY=http://192.168.31.67:10808 bash ci/provision-runner.sh
```

代理只作用于境外站点；国内源通过 `no_proxy` 白名单绕过（ustc / aliyun / sjtu /
tuna / tencent / `*.flutter-io.cn`）。注意 `dl.google.com` **不在**白名单里 ——
国内常被墙，让它走代理。

镜像落点：

- Rust → USTC（`RUSTUP_DIST_SERVER` / `RUSTUP_UPDATE_ROOT`）
- pub / flutter → `pub.flutter-io.cn` / `storage.flutter-io.cn`
- crates.io → USTC sparse index（写入 `/root/.cargo/config.toml`）
- Maven 插件仓库 → aliyun（写入 `/root/.gradle/init.gradle`）
- Gradle 代理 → `systemProp.*` 写进 `/root/.gradle/gradle.properties`

### 已知坑

- **非特权 LXC + `tar` 属主还原** —— 容器里 root 解压 tar 时，tar 默认会 chown 成归档内的 uid/gid（例如 `397546:5000`），而非特权容器的 uid 映射覆盖不到，`chown` 返回 `EINVAL`，tar 直接 `exit 2`。Flutter 内部用 tar 解压 gradle-wrapper，一旦失败会连带 `flutter pub get` 全挂。脚本导出 `TAR_OPTIONS="--no-same-owner"` 全局规避。
- **init.gradle 只能动 settings 级仓库** —— Flutter 的 `settings.gradle` 里有 `includeBuild(".../flutter_tools/gradle")`，那个 `:gradle` 子构建声明了 `repositoriesMode = PREFER_SETTINGS`。任何往 project 加仓库的写法（`allprojects` / `beforeProject`）都会命中它并直接构建失败。实测只有 `beforeSettings` 注入 `pluginManagement.repositories` 可行。另外必须用 `beforeSettings` 而非 `settingsEvaluated`，否则 aliyun 会被排到 `google()` 后面。
- **Debian 13 没有 `openjdk-17` 包** —— 必须用 Temurin tarball，脚本已处理。
- **不要反复 `rustup target add`** —— 会触发 manifest 重同步，有损坏 toolchain 的风险。脚本只在 target 缺失时才 add。
- **Actions 的 Node 步骤**需要 `node` 直接出现在 PATH —— 脚本建了 `/usr/local/bin/node` 软链。
- **NDK 压缩包约 690MB** —— 走代理时容易截断损坏。
- **`.sh` 必须 LF** —— CRLF 会让 bash 把 `set -o pipefail` 读成 `pipefail\r`，报 `invalid option name`。`.gitattributes` 已强制。

## `build-android-lib.sh`

CI 专用的 Rust 库构建脚本，**替代上游的 `flutter/ndk_arm64.sh`**（上游文件保持原样便于 rebase）。只做两处必需改动：

**`--bindgen`** —— `hwcodec` 的 `build.rs` 用 bindgen 解析 `cpp/common/*.h`。cargo-ndk 默认**不**设置 `BINDGEN_EXTRA_CLANG_ARGS_<target>`，libclang 拿不到 Android sysroot 就回退到宿主头文件，报：

```
/usr/include/stdint.h:26:10: fatal error:
'bits/libc-header-start.h' file not found
```

sysroot 的自动解析是 clang **驱动**（可执行文件）的行为，libclang 这个库没有 —— 所以把 `LIBCLANG_PATH` 指向 NDK 自带的 libclang 也救不回来，只能靠 `--bindgen`。

**`--lib`** —— `Cargo.toml` 里 `[lib] name="librustdesk" crate-type=["cdylib","staticlib","rlib"]`，APK 只需要 `liblibrustdesk.so`。上游脚本会连带编译 `rustdesk` / `service` / `naming` 三个二进制，而 `[profile.release]` 是 `lto=true` + `codegen-units=1`（fat LTO），每个链接峰值 2GB+ 内存。本实验 runner 是 6GB 的 LXC（宿主机仅 10GB，各容器超配到 14.6GB），会被压到 swap 抖动、连 sshd 都失去响应。实测 lib 先产出，之后 25 分钟全耗在那两个用不到的东西上。

产物验证：

```
liblibrustdesk.so  ELF 64-bit LSB shared object, ARM aarch64,
                   for Android 21, built by NDK r28c (13676358), stripped
```

## `build-xdesk.yml`

Gitea Actions 工作流，`runs-on: ubuntu-latest`（对应 runner 的 `ubuntu-latest:host` 标签）。

流水线：patch Flutter SDK → provision/体检 → 安装 codegen → 生成 flutter-rust-bridge → 编译 vcpkg C++ 依赖 → 编译 Rust `.so` → 签名 → `flutter build apk --release --split-per-abi` → 上传 artifact。

签名凭据从 runner 的 `/opt/xdesk/` 读取（`xdesk-release.keystore` + `key.properties`），**不进仓库**；找不到则回退 debug 签名。详见 `docs/SIGNING.md`。

### 排障：定位失败在哪一步

runner 的 `/var/lib/act_runner/config.yaml` 设 `log.level: trace`，然后：

```bash
journalctl -u gitea-runner -o cat \
  | grep -oE "(Run (Main|Post) [A-Za-z -]+|Success - (Main|Post) [A-Za-z -]+|Failure - (Main|Post) [A-Za-z -]+)" \
  | uniq
```

会直接打印出步骤序列，一眼看出挂在哪个 step。
