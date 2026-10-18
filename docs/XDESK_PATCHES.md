# Xdesk 与 rustdesk 1.5.0 的差异

本仓库是 rustdesk 1.5.0 的本地 fork。仅做了应用标识、默认服务器和构建配置的修改，其他代码与上游保持一致，方便后续 cherry-pick 上游安全更新。

## 修改清单

### 应用标识（防止被官方覆盖/识别）

| 项 | 原值 | 新值 |
|---|---|---|
| Android `namespace` | `com.carriez.flutter_hbb` | `com.xdesk.remote` |
| Android `applicationId` | `com.carriez.flutter_hbb` | `com.xdesk.remote` |
| AndroidManifest `package` | `com.carriez.flutter_hbb` | `com.xdesk.remote` |
| Kotlin 包路径 | `com/carriez/flutter_hbb/` | `com/xdesk/remote/` |
| Android `app_name` | `RustDesk` | `Xdesk` |
| Deep link scheme | `rustdesk://` | `xdesk://` |
| Boot action | `com.carriez.flutter_hbb.DEBUG_BOOT_COMPLETED` | `com.xdesk.remote.DEBUG_BOOT_COMPLETED` |

### 默认服务器（已撤销，2026-10-18）

**本 fork 不再内置任何自有服务器地址**，全部保留上游默认值：

| 项 | 现状 |
|---|---|
| `RENDEZVOUS_SERVERS` (`hbb_common/src/config.rs:117`) | `&["rs-ny.rustdesk.com"]`（上游原值） |
| 默认 API (`src/common.rs:1162`) | `https://admin.rustdesk.com`（上游原值） |
| 版本检查 (`hbb_common/src/lib.rs:511`) | `https://api.rustdesk.com/version/latest`（上游原值） |
| `is_public()` 识别 (`src/common.rs:1176`) | 仅 `rustdesk.com` / `*.rustdesk.com`（上游原值） |
| `RS_PUB_KEY` (`hbb_common/src/config.rs:118`) | 上游官方公钥，未改 |

需要连自建服务器时，在客户端「设置 → 网络 → ID/中继服务器」里填地址和 Key，
或预置 `RustDesk2.toml`。**不写进源码**，避免随仓库公开。

### 文档链接

- 保留上游 `https://rustdesk.com/docs/en/...`，未做替换。

### Flutter 包名

- `flutter/pubspec.yaml` 的 `description` 改为 `Xdesk Remote Desktop`
- **`name` 保持 `flutter_hbb` 不变**（有意为之）：Dart 包名决定了 91 个源文件里的
  `import 'package:flutter_hbb/...'`，改 `name` 会让整个 Flutter 工程编译失败。
  Dart 包名不体现在 APK 里，用户不可见，改它没有收益。应用名由
  `flutter/android/app/src/main/res/values/strings.xml` 的 `app_name` 控制。

### 仓库结构

- `libs/hbb_common` 已从 git submodule 改为主仓库内联目录（33 个文件，14291 行），便于 patch 跟随本仓库提交。
- 移除了 `.gitmodules`。

## 没改的地方（有意为之）

- **Rust crate 名** (`Cargo.toml` 里 `rustdesk`)：Rust crate 名仅影响 Rust 内部模块名，不影响应用包名，不改更利于与上游同步。
- **icon / launcher 图标**：沿用上游默认图标（都是橘色 R）。后续想换 Xdesk 图标自行替换 `flutter/android/app/src/main/res/mipmap-*/ic_launcher.*`。
- **FlutterView 入口图标 / Web favicon**：同理。
- **iOS / macOS / Windows / Linux**：这次只动 Android 端默认服务器常量，桌面端同样会拿到 xdesk 默认 server（因为是 hbb_common 的全局常量），但打包脚本 / 签名链未改。

## 如何同步上游更新

```bash
git remote add upstream https://github.com/rustdesk/rustdesk.git
git fetch upstream --depth 1 1.5.0  # 或指定新 tag
git merge upstream/1.5.x --no-edit   # 解决可能的 const 内重命名冲突
```

我们的 patch 集中在几个固定位置，merge 冲突很容易解决。

## 如何编译

**CI（推荐）**：推到 gitea `xtcer/xdesk` 的 `main` 分支即自动触发 Gitea Actions 构建，
产物在 run 页面的 artifact 里下载。详见 `docs/SIGNING.md`。

**本地**：在构建机（LXC 104）上

```bash
source /etc/profile.d/xdesk-build.sh
cd <repo>
flutter_rust_bridge_codegen --rust-input ./src/flutter_ffi.rs \
  --dart-output ./flutter/lib/generated_bridge.dart \
  --c-output ./flutter/macos/Runner/bridge_generated.h
cp ./flutter/macos/Runner/bridge_generated.h ./flutter/ios/Runner/bridge_generated.h
./flutter/build_android_deps.sh arm64-v8a
./flutter/ndk_arm64.sh
mkdir -p ./flutter/android/app/src/main/jniLibs/arm64-v8a
cp ./target/aarch64-linux-android/release/liblibrustdesk.so \
   ./flutter/android/app/src/main/jniLibs/arm64-v8a/librustdesk.so
cp $ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so \
   ./flutter/android/app/src/main/jniLibs/arm64-v8a/
cd flutter && flutter build apk --release --target-platform android-arm64 --split-per-abi
```