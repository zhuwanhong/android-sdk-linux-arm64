# 能做什么、不能做什么

**这份文件是这个项目对用户的承诺，也是它的判据。**

问题不该是「你们编了哪些二进制」，而是「**我在 mac / x86 上做的那件事，在
ARM64 Linux 上能不能做**」。所以这里按**场景**列，不按工具列。

三档状态，别混：

| | 意思 |
|---|---|
| ✅ | **等同**。同样的命令、同样的结果，有可复现的证据 |
| ⚠️ | **部分**。主路能走，某个具体能力缺，下面写明缺哪一块 |
| ❌ | **做不了**。写明为什么（多半是上游只发那几个平台），以及替代方案 |

**每一行都必须挂一条能跑的命令。** 没有证据的行不该是 ✅。

---

## 主表

<!-- parity-table-start -->

| 场景 | 状态 | 证据（拿这条命令自己验） |
|---|---|---|
| Gradle / AGP 出 debug/release APK | ✅\* | `tests/gradle-build.sh` |
| ndk-build 编原生库 | ✅ | `tests/hello-native/build.sh` |
| CMake（NDK 的 toolchain 文件）编原生库 | ✅ | `tools/make-ndk-dist.sh` 验九 |
| AGP + `externalNativeBuild`（CMake） | ✅ | `tests/gradle-build.sh`（`hello-native` 就是走 CMake 的） |
| React Native（Hermes 字节码） | ✅ | `tools/build-hermesc.sh --verify` |
| 装到真机、看 logcat | ✅ | `tests/hello-native/build.sh --install` |
| 本机起 adb 服务器 | ✅ | `tools/build-adb.sh --verify`（6/7） |
| 原生代码调试（lldb 连设备） | ✅ | `tools/verify-lldb-device.sh` |
| 静态分析（clang-tidy / clangd） | ✅ | `tools/link-system-tools.sh` |
| Vulkan shader（glslc / spirv-\*） | ✅ | 同上 |
| 看 app 的 sqlite 数据库 | ✅ | `tools/build-sqlite3.sh --verify` |
| 签名 / dex（apksigner、d8） | ✅ | 纯 Java，官方原样；`tests/` 全程用它 |
| 分析 APK（apkanalyzer / cmdline-tools） | ✅ | 纯 Java，实测读得了我们出的 APK |
| 堆转储（hprof-conv） | ✅ | 验收里跟官方产物逐字节比过 |
| 用 `sdkmanager` 装我们的包 | ✅ | `tools/make-repo.sh --verify`（起 http 真装再真跑） |
| **性能剖析（simpleperf）** | ⚠️ | 见下 |
| **IDE（Android Studio）** | ❌ | 见下 |
| 模拟器 | ❌ | 见下 |
| Layout Inspector | ❌ | 见下 |
| Android Auto 桌面模拟器（DHU） | ❌ | 见下 |
| RenderScript | ❌ | 上游 Android 12 起废弃，**决定不做** |

<!-- parity-table-end -->

\* **Gradle 那条路有一个前置条件，不设就不通**：AGP **不用** `$ANDROID_HOME` 里的
`aapt2`，它自己从 maven 解析 `com.android.tools.build:aapt2:<ver>:linux`，解开是
**x86_64 ELF**。直接敲 `./gradlew` 会挂在
`AAPT2 …-linux Daemon #0: Daemon startup failed`（实测）。

解法是给 Gradle 一个属性，指到我们这份 `aapt2`：

```properties
# ~/.gradle/gradle.properties —— 写在这儿对**所有**工程生效
android.aapt2FromMavenOverride=/opt/android-sdk/build-tools/36.0.0/aapt2
```

`tools/install.sh` 会替你写（不想让它动就加 `--no-gradle-props`）。
实测：加上这行之后，不带任何 `-P` 直接 `./gradlew assembleRelease` 就 `BUILD SUCCESSFUL`。

> **修正记录**：这一格原先写的是「AGP + externalNativeBuild 只有下游工程实测过，
> 仓库内暂无一键复现」。**那是错的** —— `tests/hello-native/build.gradle` 里本来
> 就有 `externalNativeBuild { cmake … }`，我当时只 grep 了根目录的
> `tests/build.gradle`（那儿当然没有），没看模块自己的。实测确认 AGP 真的跑了
> `configureCMakeRelWithDebInfo` / `buildCMakeRelWithDebInfo`，`CMakeCache.txt` 里
> 是 NDK 的 toolchain 文件。**这一格是 ✅，不带星号。**

---

## ⚠️ simpleperf：能录能报，但 python 那条链路不通

- **有的**：`simpleperf/bin/linux/aarch64/simpleperf`（host 那半，官方只发 x86_64，
  我们自己编的）。本机 record 1,368 个样本、report 读回 `Samples: 1368`，实测过。
- **缺的**：`libsimpleperf_report.so` —— simpleperf 那套 python 脚本用 `ctypes`
  加载它来生成报告。它要进 CPython 进程，而**一个进程里混不了 bionic 和 glibc**，
  是另一条线的活。
- **还没验的**：读**设备**上录的 `perf.data`（本机录的已验）。要真机。
- **替代**：命令行的 `simpleperf record/report` 够用；要图形报告就把 `perf.data`
  拷到 x86 机器上用官方那套 python 脚本。

## ❌ Android Studio：官方没有 Linux ARM64 构建

2026-08-30 查 developer.android.com/studio，发的是
`Windows (64-bit)` / `Mac (64-bit)` / `Mac (64-bit, ARM)` / `Linux (64-bit)` / `ChromeOS`
—— **Mac 有 ARM，Linux 没有**。跟 `emulator`、`skiaparser` 同一个模式。

**这一条我们补不了**（Studio 是 IDE 产品，不是 SDK 组件）。替代：

- **IntelliJ IDEA Community 有 `linuxARM64`**（查 JetBrains 的 releases API，
  2025.3 实有该平台）。Android 插件能装，Gradle 那条路照走。
- 或者 VS Code / 任意编辑器 + 本仓库的命令行链路 —— 本表里 ✅ 的那些**全都是
  命令行**，不依赖 IDE。

## ❌ 模拟器

官方 `emulator` 只发 `linux/x64`、`macosx/aarch64`、`windows/x64`，没有
`linux/aarch64`。**决定不做**，三条理由见 README 路线图第 7 条（简言之：它当初是
当验证手段排进来的，而真机那条路已经走通；这台机器没 KVM；工程量是 QEMU fork
级别）。替代：**真机走 adb**（本表里那几条 ✅ 就是这么验的），或 **Cuttlefish**
（AOSP 官方虚拟设备，自己就发 arm64 host 的包，但要 KVM）。

## ❌ Layout Inspector / Android Auto DHU

`skiaparser`、`extras;google;auto` 都是**闭源**，官方只发那几个平台（而且都有
macOS ARM64 构建，就是不发 Linux ARM64）。源码找不到，我们编不了。
详见 README 路线图第 8、9 条。

---

## 怎么复核这张表

```bash
tools/verify-claims.sh          # 第一、二节那些事实（含 Google 发了哪些平台）
tests/gradle-build.sh           # AGP 整条路
tests/hello-native/build.sh     # 手工流水线（--install 需要真机）
tools/verify-lldb-device.sh     # 连设备调试（没设备时退出码 2 = 没条件验，不是失败）
```

**退出码的约定**：`0` = 验过了，`1` = 真失败，`2` = 没条件验（缺设备、缺隧道…）。
把 `2` 当成失败会让「没测」冒充「测挂了」，把它当成成功则相反 —— 两种都错。

配套的机器可读版本在 [`parity.json`](../parity.json)，字段跟本表一一对应，
CI 和脚本可以直接断言。
