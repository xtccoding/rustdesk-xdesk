# 手动构建流程（不用 AI）

本仓库 `xtccoding/rustdesk-xdesk` 是 rustdesk 1.5.0 的公开 fork，包名改成 `com.xdesk.remote`，
源码里**不含任何服务器地址和 key**。Windows x64 版本在 GitHub 托管的 windows-2022 机器上编译，
公开仓库的 Actions 分钟数不收费。

---

## 一、准备（只做一次）

1. 浏览器登录 GitHub，确认能看到 `https://github.com/xtccoding/rustdesk-xdesk`。
2. 本地已 clone 过的话，确认远程指向新名字（改名后旧 URL 会自动重定向，但建议改掉）：

```bash
git remote set-url gh https://github.com/xtccoding/rustdesk-xdesk.git
git remote -v
```

3. 本机需要 git；`gh` CLI 可选，纯网页也能做完全部流程。

---

## 二、每次改代码 → 出 Windows 包

### 第 1 步：同步最新代码

```bash
cd ~/Desktop/rustdesk-upstream      # 换成你的目录
git checkout main
git pull gh main
```

### 第 2 步：改代码

只改你要改的文件。改完先自查，**这一步不能省**：

```bash
git diff
git diff | grep -iE "xen\.autos|\.88:|pub_key|RS_PUB_KEY"   # 有输出就说明你把服务器信息又写进去了
```

### 第 3 步：提交并推送

```bash
git add -A
git commit -m "说明你改了什么"
git push gh main
```

### 第 4 步：在网页上点构建

1. 打开 `https://github.com/xtccoding/rustdesk-xdesk/actions`
2. 左侧点 **xdesk Windows x64**
3. 右上 **Run workflow** → 分支选 `main` → **Run workflow**
4. 页面刷新，会出现一条新的运行记录

纯网页改代码的话，第 2、3 步可以在 GitHub 网页上直接编辑文件 → Commit changes，然后跳到第 4 步。

### 第 5 步：等结果

三个任务按顺序来，总耗时大约 40–70 分钟（首次没有缓存会更久）：

| 任务 | 作用 | 大约耗时 |
|---|---|---|
| build-RustDeskTempTopMostWindow | 编译窗口置顶用的 C++ 组件 | 1 分钟 |
| generate_bridge（两个） | 生成 flutter ↔ rust 桥接代码 | 10–30 分钟 |
| build-windows-x64 | 真正编译 Windows 客户端 | 30–50 分钟 |

### 第 6 步：下载产物

1. 打开这次运行记录，等 `build-windows-x64` 变绿勾
2. 页面底部 **Artifacts** → 点 `rustdesk-windows-x86_64`（保留 14 天，过期就重跑）
3. 下载 zip，解压得到 `rustdesk.exe` 和一堆 dll，整个目录一起用，不能只拿 exe

---

## 三、失败怎么查

| 现象 | 原因 | 处理 |
|---|---|---|
| `Move-Item` / `找不到 windows-x64-release` | flutter 引擎目录没拷过去 | 看 workflow 里"替换 flutter 引擎"那步，路径要用 `Get-Command flutter` 反推，不能写死 hostedtoolcache 路径 |
| vcpkg 编译报错、卡很久 | vcpkg 二进制缓存没命中 | 重跑一次，第二次会走缓存；仍失败就点 **Clear cache** 工作流 |
| 6 小时后超时 | 首次全量编译 | 重跑，有缓存后会快 |
| `build-windows-x64` 一直不出现 | 它 `needs` 前两个任务 | 等前两个完成才会排队，正常 |

---

## 四、绝对不能做的事

1. **不要往仓库里提交服务器地址、`key`、`id_ed25519`、签名文件。** 仓库是公开的，一旦推上去就等于公开，
   即使后面删掉，历史里也还在（需要重写历史 + force-push 才干净）。
2. 需要连自建服务器时，在客户端 **设置 → 网络 → ID/中继服务器** 里填地址和 Key，
   或者只在自己机器上放 `RustDesk2.toml`。配置属于运行时，不属于源码。
3. 不要给 `ci.yml` / `flutter-ci.yml` 恢复 `push` 触发。它们是上游的全平台矩阵，一推就烧几百分钟，
   现在 `push.branches` 已被改成占位符 `ci-disabled-in-fork`。
4. 不要把这个 fork 和另一个自研的 `xdesk` 工程搞混：这里只是改了包名的 rustdesk。

---

## 五、跟着上游升级

```bash
git fetch upstream
git log --oneline HEAD..upstream/master | head        # 看上游新提交
git merge upstream/master                              # 或者只 cherry-pick 安全补丁
```

冲突大概率集中在 `libs/hbb_common/src/config.rs`、`src/common.rs`、`flutter/` 下的品牌相关行。

---

## 六、MSI 和 deb 是怎么打出来的

这两个包的是同一份已经编译好的程序，区别只在"用哪个工具把文件塞进容器"。
本仓库的 `xdesk Windows x64` 工作流**只产出绿色版目录**（artifact 里的 `rustdesk/`），
下面两种是上游的官方打包方式，需要的话可以加进工作流。

### MSI（Windows 安装包）

用 **WiX v4**（微软官方的 MSI 编译器），工程在 `res/msi/`：

```
res/msi/
  msi.sln                  Visual Studio 解决方案
  Package/Package.wxs      MSI 主定义：产品名、升级码、安装流程
  Package/Includes.wxi     变量区（版本号、厂商、安装目录），由脚本填
  Package/Components/      "每个文件一个 component" 的清单，由脚本生成
  Package/Fragments/       升级规则、ARP（控制面板里的卸载项）属性
  Package/UI/              安装向导界面
  CustomActions/           C++ 写的自定义动作 DLL
  preprocess.py            生成上面这些 .wxs/.wxi 的脚本
```

流程：

1. `python preprocess.py -d <绿色版目录> --app-name ...`
   扫描绿色版目录里每个文件，生成 WiX 的 `Component` 清单（相当于 WiX 官方的 heat），
   同时把版本号、产品名、升级 GUID、ARP 信息写进 `Includes.wxi` / `Fragments/`。
   **它是在原地改写 `res/msi` 下的文件**，所以 CI 打完要 `git checkout -- res/msi` 还原。
2. `nuget restore msi.sln` 拉 WiX 的 NuGet 包（不用单独装 WiX，msbuild 直接从 NuGet 取）。
3. `msbuild msi.sln -p:Configuration=Release -p:Platform=x64 /p:TargetVersion=Windows10`
   产出 `Package/bin/x64/Release/en-us/Package.msi`。
4. `CustomActions` 这个 C++ DLL 干 MSI 本身做不到的事：装 Windows 服务、加防火墙规则、
   读配置、装远程打印机驱动。它在 MSI 里作为立即/延迟执行的自定义动作被调用。

CI 里还会多跑一遍，把 exe 名和应用名换成占位符（`RDAPPNAM.exe`），产出一个"MSI 模板"。
那是上游发版流程用的：以后换品牌名只改模板里的属性，不用重新编译整个 MSI。

### deb（Debian / Ubuntu 安装包）

用 **`dpkg-deb`**，不需要额外工具链，脚本是根目录 `build.py` 的 `build_flutter_deb()`：

1. `flutter build linux --release` → 得到 `flutter/build/linux/x64/release/bundle/`
2. 在 `flutter/tmpdeb/` 里搭一个假的根目录，按 FHS 摆放：

| 包内路径 | 内容 |
|---|---|
| `usr/share/rustdesk/` | 整个 bundle（可执行文件、`data/`、`lib/`） |
| `usr/bin/rustdesk` | 软链到 `/usr/share/rustdesk/rustdesk` |
| `usr/share/applications/` | `rustdesk.desktop`、`rustdesk-link.desktop` |
| `usr/share/icons/hicolor/` | 256x256 png + scalable svg |
| `usr/share/rustdesk/files/systemd/` | `rustdesk.service` |
| `usr/share/polkit-1/actions/` | polkit 授权策略 |

3. `generate_control_file()` 写出 `DEBIAN/control`（包名、版本、架构、依赖列表），
   再 `cp -a res/DEBIAN/*` 把 `preinst / postinst / prerm / postrm` 四个维护脚本放进去
   —— 装服务、建用户、升级时停旧服务全靠这四个脚本。
4. `md5_file_folder()` 生成 `DEBIAN/md5sums`。
5. `dpkg-deb -b tmpdeb rustdesk.deb` → 标准 deb，`apt install ./rustdesk.deb` 就能装。

架构由 `DEB_ARCH` 环境变量控制（amd64 / arm64），CI 里按 matrix 传入。

### 想给这个 fork 也加上

- MSI：在 `xdesk-windows.yml` 的 `build-windows-x64` 之后加一步 `pushd res/msi` + `nuget restore` + `msbuild`。
  windows-2022 runner 自带 nuget 和 msbuild，不用额外装。产品名/厂商改 `preprocess.py` 的参数。
- deb：新增一个 `ubuntu-22.04` 任务跑 `python3 build.py --flutter --skip-cargo`，产物 `rustdesk-<version>.deb`。
