# Xdesk 签名与 CI 说明

Xdesk 是 rustdesk 1.5.0 的本地 fork，应用标识 `com.xdesk.remote`，服务器地址不内置（走客户端设置）。

## 为什么仓库里没有 keystore

release 签名用的 `key.properties` 与 `xdesk-release.keystore` **不会** 提交到仓库。

- 仓库内只有模板：`flutter/android/app/key.properties.template`
- `.gitignore` 已排除 `key.properties`、`*.keystore`、`*.jks`
- 真实 keystore 放在构建机（gitea runner）本地目录 `/opt/xdesk/`，由 workflow 在构建时拷进源码树

## 签名文件在源码树中的位置（重要）

`flutter/android/app/build.gradle` 里是这样读的：

```groovy
def keystorePropertiesFile = rootProject.file('key.properties')   // → flutter/android/key.properties
...
storeFile keystoreProperties['storeFile'] ? file(keystoreProperties['storeFile']) : null  // → 相对 app/ 解析
```

所以：

| 文件 | 必须放的位置 |
|---|---|
| `key.properties` | `flutter/android/key.properties`（**不是** `app/` 下） |
| `xdesk-release.keystore` | `flutter/android/app/xdesk-release.keystore` |

`key.properties` 内容：

```properties
storePassword=xdesk2026xtcer
keyPassword=xdesk2026xtcer
keyAlias=xdesk
storeFile=xdesk-release.keystore
```

## 构建机（gitea runner, LXC 104 / 192.168.31.205）

签名材料存放目录：`/opt/xdesk/`

```
/opt/xdesk/key.properties            (600)
/opt/xdesk/xdesk-release.keystore    (600)
```

workflow 的 `Setup signing` 步骤会自动拷贝；如果该目录不存在，则回退成 debug 签名
（`sed -i "s/signingConfigs.release/signingConfigs.debug/g"`），构建不会因此失败。

## CI：Gitea Actions

工作流：`.gitea/workflows/build-xdesk.yml`

- 触发：push 到 `main`，或手动 `workflow_dispatch`
- runner：`runner-01`（LXC 104），host 模式，标签 `ubuntu-latest:host`
- 产物：`xdesk-<version>-arm64-<run_number>.apk`（`actions/upload-artifact`）

构建链：`flutter_rust_bridge` 生成 → vcpkg C++ 依赖 → `cargo ndk` 编 Rust 静态库 →
拷 `.so` 到 jniLibs → `flutter build apk --release --split-per-abi`。

### 构建机环境

| 组件 | 版本 / 路径 |
|---|---|
| Flutter | 3.24.5 → `/opt/flutter` |
| Rust | 1.75.0（rustup default）→ `/root/.cargo` |
| cargo-ndk | 3.1.2 |
| Android SDK | `/opt/android-sdk`（platform-tools / platforms;android-36 / build-tools;36.0.0 / cmake;3.22.1） |
| Android NDK | `r28c` = 28.2.13676358 → `/opt/android-sdk/ndk/` |
| JDK | Temurin 17 → `/opt/jdk-17`（Debian 13 已无 openjdk-17） |
| vcpkg | `/opt/vcpkg` @ `9e593bb18ea69cc5095e012465dcd675a822ed0d` |
| Node.js | 20.19.2（`actions/checkout` 等 Node 动作必需） |

环境变量统一由 `/etc/profile.d/xdesk-build.sh` 提供，workflow 每个 `run` 步骤先 `source` 它。

### 网络

LXC 104 无直连外网，所有外网流量走代理 `http://192.168.31.67:10808`：

- `gitea-runner.service` 的 drop-in：`/etc/systemd/system/gitea-runner.service.d/proxy.conf`
  （同时把 `HOME` 设为 `/root`，让 cargo/gradle/pub 缓存与构建机环境一致）
- 全局：`/etc/profile.d/xdesk-build.sh`
- Gradle：`/root/.gradle/gradle.properties` 的 `systemProp.*.proxyHost`

> 注意：NDK r28c 的 zip 约 689 MB，经 CF Workers 代理下载会被截断（`Error on ZipFile unknown archive`）。
> 需要从能直连外网的机器下载后 `scp` 到 `/opt/android-sdk/ndk/28.2.13676358`。

## 初次签名密钥生成

```bash
keytool -genkeypair -v \
  -keystore xdesk-release.keystore \
  -storepass <STORE_PASSWORD> \
  -keypass <KEY_PASSWORD> \
  -alias xdesk \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -dname "CN=Xdesk, OU=xtcer, O=xtcer, L=Shanghai, ST=Shanghai, C=CN"
```

当前密码：`xdesk2026xtcer`（alias `xdesk`）。
**该 keystore 决定 APK 的升级签名，务必留备份；丢了就无法对已装设备做覆盖升级。**
