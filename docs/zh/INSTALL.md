# 装上就能编 Android app

给**用这个包**的人看的。想知道它是怎么编出来的，看 [README](../../README.md)。

Google 只为 `linux-x86_64` 发布 Android 的构建工具。这个包补上 `linux-aarch64`
那一份——装完之后，**你原来那套 `./gradlew` / `ndk-build` 命令一个字都不用改**。

---

## 一条命令（推荐）

```bash
git clone https://github.com/zhuwanhong/android-sdk-linux-arm64
cd android-sdk-linux-arm64
tools/install.sh --sdk-root ~/Android/Sdk \
    --sdk-tgz /path/to/android-sdk-linux-arm64-36.0.0.tar.gz \
    --ndk-tgz /path/to/android-ndk-27.1.12297006-linux-aarch64.tar.gz \
    --platform 36
```

`--build-tools 36.1.0` 可以把我们的二进制装到别的 build-tools 版本下。
Google 发着 82 个版本、工程里是钉死的，而我们编的二进制来自 AOSP 源码、
**跟版本号没有内在关系** —— 安装器取那个版本的官方文件，再把我们的铺上去。
2026-08-31 实测 `36.1.0`：AGP 整条路通，两个样例 APK 都出。

> **AGP 自己也有默认的 `buildToolsVersion`**（AGP 9.3.2 是 36.0.0）。模块里不钉
> 的话它要那个默认值，没装就报 `Failed to install … some licences have not been
> accepted: build-tools;36.0.0` —— **这句话很误导，真实原因是「那个版本没装」，
> 不是许可问题**。所以用了 `--build-tools`，工程里每个模块都要钉同一个版本。

它做四件事，**每一件都是不做就用不了的**：

1. 解两个包；
2. 把 `cmake` / `ninja` / `lldb` / `clangd` / `glslc` 接进来 —— 不接的话
   **AGP 会自己下一份 x86_64 的 cmake 装进你的 SDK**；
3. 补 `platforms/android-XX`（我们有意不分发它，见第 3 节）——
   地址是问官方 manifest 要的，不写死修订号；
4. 往 `~/.gradle/gradle.properties` 写一行 `android.aapt2FromMavenOverride` ——
   **AGP 不用 `$ANDROID_HOME` 里的 `aapt2`**，它从 maven 拉 x86_64 那份，
   不覆盖就挂在 `AAPT2 …-linux Daemon #0: Daemon startup failed`。

最后它**当场自证**：真跑 `aapt2`、真起一次 `adb` 服务器（用非默认端口）、
真跑 NDK 的 `clang`、**真编一个带原生库的 APK 出来**。退出码 `0` 才算装好。

不想让它动 `~/.gradle` 就加 `--no-gradle-props`（那你得自己给 Gradle 传
`-Pandroid.aapt2FromMavenOverride=…`）。离线机器用 `--platform-from /path/to/别的SDK`
从已有 SDK 拷 `platforms/`。

**装完能做什么、不能做什么**，按场景列在 [PARITY.md](PARITY.md)。

---

> ### 一定要钉 `ndkVersion`，否则 AGP 会下一个 x86_64 的 NDK
>
> 我们发的是 **NDK 27.1.12297006**（唯一标 LTS 的那个，也是 React Native 钉的）。
> 而 AGP 自己有默认值 —— AGP 9.3 是 **28.2.13676358**（Flutter 钉的也是它），
> 模块里不写 `ndkVersion` 就用那个。
>
> 2026-08-31 实测：把钉去掉之后，AGP 9.3.2 **一声不响地下载并安装了
> NDK 28.2.13676358**（2.2 GB）。它里面只有 `linux-x86_64`，clang 在 ARM64 上
> 根本 exec 不了。
>
> ```gradle
> android {
>     ndkVersion '27.1.12297006'   // 每个带原生代码的模块都要写
> }
> ```
>
> 想自己编别的 NDK 版本：`tools/build-ndk-version.sh` 会去查那个 NDK 用的
> Clang 修订号，并把 LLVM 的构建钉到它上面。

## 另一条路：内部的 `sdkmanager` 镜像

`tools/make-repo.sh` 能把一棵完整的 SDK 树做成 **`sdkmanager` 认得的仓库**，
`sdkmanager` 和 Android Studio 的 SDK Update Sites 都照常用，**工程一个字都不用改**。
给一整批机器铺 ARM64 工具链时用这个。

> **这是内部分发用的，不是公开发布用的**，两条理由都是实测出来的：
>
> 1. **包里必然含 Google 的文件。** sdkmanager 的包是自带 `source.properties` 的
>    完整单元，所以 zip 里必须有 `d8.jar` / `apksigner` / 包装脚本那些。
>    拿 `--ours-only` 那棵树做也不行 —— 它没有 `source.properties`，脚本会当场
>    报「读不出 Pkg.Revision」。
> 2. **它只能装进「还没有该包」的干净 SDK 根。** 2026-08-31 实测：往一个已装官方
>    `build-tools;36.0.0` 的根上装，sdkmanager 取到了我们的 `repository2-3.xml`，
>    判定同版本已安装、**什么都不做** —— 我们的 `aapt2` 一个字节都没进去。
>    它不是「覆盖官方那份」的手段。
>
> 所以：在已经有官方 SDK 授权的团队内部建一次、内部分发。对外发布走 tarball +
> `tools/install.sh`（只发我们编的，官方部分装的时候取）。

```bash
# 1) 把仓库目录发出去（任意静态 http 都行）
(cd /path/to/repo && python3 -m http.server 8099)

# 2) 指过去装。**结尾那个斜杠不是可有可无的**
export SDK_TEST_BASE_URL=http://127.0.0.1:8099/
sdkmanager --sdk_root=$ANDROID_HOME "build-tools;36.0.0" "platform-tools"
```

> ⚠️ **`SDK_TEST_BASE_URL` 少了结尾的 `/` 会静默失效。** `sdkmanager` 里
> `REPO_URL_PATTERN` 是 `%srepository2-%d.xml`，少个斜杠就拼成
> `http://127.0.0.1:8099repository2-3.xml`，它判成非法**直接忽略、一个请求都不发**。
> 实测对照：不带斜杠 → `Warning: Ignoring invalid SDK_TEST_BASE_URL`、请求数 0；
> 带斜杠 → 列出我们的包、请求数 6。
>
> （这条我们自己也栽过：当初的结论写成「sdkmanager 不认这个环境变量」，
> 其实是参数不对。）

Android Studio 那边是 **Settings → Languages & Frameworks → Android SDK →
SDK Update Sites**，把 `http://<主机>:8099/` 加进去。

**仓库怎么来的**：`tools/make-repo.sh`（先跑 `tools/make-dist.sh` 摆好目录）。
它自己会验两件事，**都是真验不是格式检查**：

- 用 **Google 官方的 XSD** 校验产出的 `repository2-3.xml`——而且**先在 Google 自己
  那份 XML 上校准**（官方那份必须先通过，否则说明是校验器搭错了，不是我们的 XML 有问题）。
  XSD 从 `cmdline-tools` 的 jar 里自动取，不用手动准备。
- `tools/make-repo.sh --verify` **真起一个 http 服务、真让 `sdkmanager` 装一遍、
  再把装出来的二进制真跑一次**（实测：15 个请求，两个二进制都是 aarch64 且能跑）。

> ⚠️ **别用 `sdkmanager` 从 Google 官方源装 `build-tools` / `platform-tools`。**
> 那会把 x86_64 的二进制装进来盖掉我们的。要装就指到我们的仓库（上面那条）。

---

下面是**一步步手动来**的版本，想知道每步在干什么、或者上面那条命令挂了要排查的话看这里。

## 从哪拿这两个包

需要两个 tar.gz：

| | 里面是什么 | 多大 |
|---|---|---|
| `android-sdk-linux-arm64-<ver>.tar.gz` | `build-tools/`、`platform-tools/` —— aapt2 / d8 / apksigner / zipalign / adb… | 几十 MB |
| `android-ndk-<ver>-linux-aarch64.tar.gz` | 整个 NDK，含自己编的 clang 18 + lld + CPython | 563 MB |

**两条路：**

1. **从 Releases 下**（如果有）——
   [github.com/zhuwanhong/android-sdk-linux-arm64/releases](https://github.com/zhuwanhong/android-sdk-linux-arm64/releases)。
   下完对一下 sha256，Release 说明里会给。

2. **自己编。** 要一台 ARM64 机器、**40 GB 磁盘、8 GB 内存**，编 LLVM 约一小时：

   ```bash
   git clone <本仓库> && cd android-sdk-linux-arm64
   tools/build-llvm.sh --fetch && tools/build-llvm.sh --build   # 慢的是这步
   tools/build-python.sh --fetch && tools/build-python.sh --build
   tools/make-dist.sh                                            # 出 SDK 包
   tools/make-ndk-dist.sh /path/to/官方NDK                        # 出 NDK 包
   ```

   细节见 [README 第六节](../../README.md)。

> 第 2 条正是这个项目要替你省掉的事。**如果 Releases 是空的，说明还没发布**——
> 那这份文档你只能照第 2 条走。

---

## 零、先确认这台机器能装

```bash
uname -m                              # 要 aarch64
ldd --version | head -1               # glibc 版本，见下
```

**glibc 版本是硬门槛。** 包里的二进制是在 Ubuntu 24.04（glibc 2.39）上编的，
比它老的系统上**开都开不起来**，报 `version GLIBC_2.xx not found`——那跟「缺个库」
不是一回事，装什么都补不上。

| 你的系统 | glibc | 能装吗 |
|---|---|---|
| Ubuntu 24.04+ | 2.39 | ✅ 裸容器实测：从零编出 APK |
| Debian 13 | 2.41 | 大概可以（没验过，但高于门槛） |
| **Ubuntu 22.04** | 2.35 | ✅ **裸容器实测**：从零编出 APK |
| **Debian 12** | 2.36 | ✅ **裸容器实测**：从零编出 APK |
| 更老的（glibc < 2.34） | — | ❌ 开都开不起来 |

> **门槛是 `GLIBC_2.34`**（2026-08-29 量的：包里 32 个 host 二进制里最高的那个
> 符号版本）。一开始是 `2.38` —— 因为**门槛跟着编译机走**，而打包机是 24.04。
> 后来改成在 `ubuntu:22.04` 容器里编那三样 host 工具
> （`tools/build-in-container.sh`），门槛就落到了 2.34。
>
> 三个镜像都是 `tools/test-clean-machine.sh --docker` 跑出来的，不是推的。

> 这是取舍不是 bug：Google 拿老 sysroot 编，门槛低到 `GLIBC_2.16`；我们直接在
> 打包机上编，省掉维护一套 sysroot，代价就是门槛跟着打包机走。
> 想自己在老系统上编一份，看 README 第六节。

---

## 一、装

### 1. 系统依赖

```bash
sudo apt update && sudo apt install -y make zip curl unzip file openjdk-21-jdk-headless
```

这几样**不在包里**，各有原因：

| | 为什么不带 |
|---|---|
| `make` | 官方 NDK 的 `prebuilt/` 里那个是 x86 的，丢了；`ndk-build` 找不到会退回系统的 |
| JDK | `javac` / `d8` / `apksigner` 要，官方 SDK 也一样是外部依赖 |
| `zip` `curl` `unzip` | 打包和下载用 |
| `file` | `tests/hello-native/build.sh` 拿它判产物架构。**裸容器实测时才发现漏了**：24.04 上一路绿到最后一步，然后挂在 `file: command not found` |

用 React Native 的话还要 `openjdk-17-jdk-headless`（它的 gradle 插件锁死要 17，
本机没有会去 GitHub 下 185 MB）和 node 20+（Ubuntu 24.04 自带的是 18，不够）。

> ⚠️ **React Native 打 release 包还缺一样，而且不是这个包能给的：`hermesc`。**
> release 构建要把 JS 编成 Hermes 字节码（`.hbc`），干这活的 `hermesc` 来自 npm 的
> `hermes-compiler` 包 —— 那个包**一共只发三个二进制**：win64、osx、linux64（x86_64）。
> **没有 ARM Linux 版。** RN 的 Gradle 插件自己就写死了这一点
> （`@react-native/gradle-plugin` 的 `utils/PathUtils.kt:189`）：
>
> ```kotlin
> if (Os.isWindows()) return "win64-bin"
> if (Os.isMac()) return "osx-bin"
> if (Os.isLinuxAmd64()) return "linux64-bin"
> error("OS not recognized. Please set project.react.hermesCommand ...")
> ```
>
> 在 ARM64 Linux 上它直接报这个错，**而错误信息就是解法**。本仓库提供
> `tools/build-hermesc.sh`，自己编一份（见 [README](../../README.md) 第三节）。
> 编好之后三条路任选一条，都不用打补丁：
>
> ```groovy
> // android/build.gradle
> react { hermesCommand = "/path/to/hermesc" }
> ```
> ```bash
> export REACT_NATIVE_OVERRIDE_HERMES_DIR=/path/to/hermes-source   # 会找 <它>/build/bin/hermesc
> cp /path/to/hermesc node_modules/react-native/sdks/hermes/build/bin/hermesc
> ```
>
> **版本不能凑合**：字节码格式跟 RN 版本绑死。对应关系在你自己的工程里就能读到 ——
> `node_modules/react-native/sdks/.hermesv1version`（RN 0.87.1 是
> `hermes-v250829098.0.17`），`tools/build-hermesc.sh` 默认编的就是这个 tag，
> 换版本用 `HERMES_TAG=` 指过去。

### 2. 解压两个包

```bash
export ANDROID_HOME=$HOME/Android/Sdk
mkdir -p "$ANDROID_HOME"
tar -C "$ANDROID_HOME" -xzf android-sdk-linux-arm64-*.tar.gz
tar -C "$ANDROID_HOME" -xzf android-ndk-*-linux-aarch64.tar.gz
```

解压出来是 `build-tools/`、`platform-tools/`、`ndk/<版本>/`，位置跟 `sdkmanager`
装的一样。**已经有一套 x86_64 SDK 的话，这两条命令就是原地覆盖**，覆盖完那套
SDK 就能在 ARM 上用了。

### 3. 补 `platforms/`（包里没有）

`platforms/android-XX/android.jar` 是**纯 Java + 数据，跟架构无关**，Google 官方
那份任何机器都能用——所以我们不重新分发它。自己下一份：

```bash
curl -fsSLO https://dl.google.com/android/repository/platform-36_r02.zip
mkdir -p "$ANDROID_HOME/platforms"
unzip -q platform-36_r02.zip -d "$ANDROID_HOME/platforms"
```

`compileSdk` 是别的版本就下对应的那个。也可以用官方 `cmdline-tools` 里的
`sdkmanager`（纯 Java，在 ARM 上跑得动）：

```bash
sdkmanager --install "platforms;android-36"
```

> ⚠️ **别用 `sdkmanager` 装 `build-tools` 或 `platform-tools`。**
> 那会把 Google 的 x86_64 二进制装进来，正好盖掉我们刚铺的 ARM 版，
> 然后你就回到起点了。它只该用来装跟架构无关的东西（`platforms`、`licenses`）。

### 4. 环境变量

```bash
cat >> ~/.bashrc <<'RC'
export ANDROID_HOME=$HOME/Android/Sdk
export ANDROID_SDK_ROOT=$ANDROID_HOME
export ANDROID_NDK_HOME=$(ls -d $ANDROID_HOME/ndk/*/ | head -1)
export PATH=$ANDROID_HOME/platform-tools:$PATH
RC
```

---

## 二、验一遍

**别信「装完了」，跑一遍。** 三条，从便宜到贵：

```bash
# 1. 编译器能不能起来
"$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/linux-aarch64/bin/clang --version

# 2. ndk-build 能不能编出 .so
mkdir -p /tmp/t/jni && printf 'int f(void){return 42;}\n' > /tmp/t/jni/x.c
printf 'LOCAL_PATH := $(call my-dir)\ninclude $(CLEAR_VARS)\nLOCAL_MODULE := x\nLOCAL_SRC_FILES := x.c\ninclude $(BUILD_SHARED_LIBRARY)\n' > /tmp/t/jni/Android.mk
"$ANDROID_NDK_HOME"/ndk-build NDK_PROJECT_PATH=/tmp/t APP_ABI=arm64-v8a NDK_APPLICATION_MK=/dev/null
file /tmp/t/libs/arm64-v8a/libx.so        # 该是 ARM aarch64

# 3. 整条链能不能出 APK（要 clone 本仓库）
tests/hello-native/build.sh
```

---

## 三、Gradle 项目还要多做一件事

**AGP 不用 `$ANDROID_HOME` 里那个 `aapt2`。** 它从 maven 解析
`com.android.tools.build:aapt2:<ver>:linux`，解开用里面的 **x86_64 ELF**。
所以把 SDK 里的 `aapt2` 换成 ARM 版，**本身不起任何作用**。自己看一眼：

```bash
find ~/.gradle -name 'aapt2-*-linux.jar' \
  -exec sh -c 'unzip -p "$1" aapt2 | file -' _ {} \;
# → ELF 64-bit LSB executable, x86-64
```

掰回来的是这一行，写进项目的 `gradle.properties`：

```properties
android.aapt2FromMavenOverride=/home/你/Android/Sdk/build-tools/36.0.0/aapt2
```

**先别加，直接 `./gradlew assembleDebug` 试。**「哪些 AGP 版本需要它」查下来
说法不一，不值得凭版本号判断。

2026-08-29 在 Gradle 9.7.1 + AGP 9.3.2 上实测，不加时报的是这个：

```
AAPT2 aapt2-9.3.2-15703166-linux Daemon #0: Unexpected error output:
  …/aapt2: 1: Syntax error: word unexpected (expecting ")")
> AAPT2 … Daemon startup failed
```

**注意它长得不像架构问题** —— 那是 `sh` 在把 x86-64 的 ELF 当脚本读。同一个
文件你自己在终端里跑，bash 说的才是 `cannot execute binary file: Exec format
error`（退出码 126）。两句话说的是同一件事。

### 资源优化那一步：新包不用管，旧包要关

```properties
android.enableResourceOptimizations=false
```

**2026-08-29 之后打的包不需要这一条**（`aapt2` 打了
`patches/aapt2/0001-flag-equals-value.patch`）。拿不准就探一下：

```bash
$ANDROID_HOME/build-tools/*/aapt2 optimize --resource-path-shortening-map=/dev/null
# 报 unknown option → 是旧包，要加上面那条
# 报 must have one APK as argument → 是新包，不用加
```

**旧包不关的话，构建会「成功」，但 APK 里没有 `AndroidManifest.xml`、也没有
`resources.arsc`。** 原因是 AGP 那一步这样调 aapt2：

```
aapt2 optimize <ap_> --shorten-resource-paths --resource-path-shortening-map=<路径> -o <输出>
```

这个包里的 aapt2 只认空格形式的参数，`--选项=值` 一律报 `unknown option` 并退出 1，
**而 AGP 把这个失败吞了**。发现它的方式是 `aapt2 dump badging your.apk` 报
`could not identify format of APK`。详情和根治方案见 [README 第三节第 3 条](../../README.md)。

### CMake（只有带 native 代码的项目用得到）

SDK 自带的 `cmake/<ver>/bin/{cmake,ninja}` 也是 x86_64，我们没重编。用系统的：

```bash
sudo apt install -y cmake ninja-build
```

然后在 `android/local.properties` 里 `cmake.dir=/usr`。

**2026-08-29 在真机上验过了**（Ubuntu 24.04 arm64，系统 cmake 3.28.3 + ninja
1.11.1，AGP 9.3.2）：AGP **认这条**，版本号对不上也不拦——它直接用你指的那份，
拿 NDK 的 `android.toolchain.cmake` 编出了 `arm64-v8a` 的 `.so`。

**还有一条更省事的**（2026-08-29 实测）：**AGP 是按目录名挑 cmake 的，
不按二进制自报的版本号挑。** 所以把系统那份摆成 AGP 默认要的那个号就行，
`cmake.dir` 一个字都不用写：

```bash
tools/link-system-tools.sh          # 它会建 cmake/<系统版本>/ 和别名 cmake/3.22.1 -> <系统版本>
```

实测证据：`local.properties` 里只有 `sdk.dir`，构建通过，而 CMakeCache 里是
`CMAKE_MAKE_PROGRAM=<SDK>/cmake/3.22.1/bin/ninja` 配
`CMAKE_CACHE_MINOR_VERSION=28` —— 目录叫 3.22.1，跑的是 3.28。

**不设 `cmake.dir`、也没有那个别名目录时，后果比「用不了」更烦**：AGP 会自己去 Google 的仓库下一份
`cmake;3.22.1` 装进你的 SDK（61 MB），而那个包**只有 x86_64**，然后报

```
…/sdk/cmake/3.22.1/bin/cmake: 1: Syntax error: ")" unexpected
```

跟上面 aapt2 那条是同一个形状：`sh` 在读 x86-64 的 ELF。**所以这条别省。**

---

## 四、有一个软链是故意留的

```
ndk/<ver>/toolchains/llvm/prebuilt/linux-x86_64 -> linux-aarch64
```

包里的 NDK 打过补丁，四处写死的 host tag 都改成按架构判断了（两个 cmake
toolchain 文件、`make_standalone_toolchain.py`、`init.mk`）。**但第三方工具不读
我们的补丁**——它们照 Google 那份写死的路径直接拼 `linux-x86_64/bin/clang`，
找不到就判这份 NDK 不合格。这个软链让两条路都通。别删它。

---

## 五、验到哪一步了

- **验了**（真机，全新 Ubuntu 24.04 / aarch64 实例，什么都没装）：解压完 `clang`
  直接跑起来；装个 `make` 就能 `ndk-build` 出 `arm64-v8a` 的 `.so`；补上 JDK 和
  `platforms/` 之后一路出 APK，装到真机能跑。
- **没验**：Gradle / AGP 那条路（第三节）；`cmake.dir=/usr`；比 24.04 老的发行版；
  非 Debian 系。撞上问题请开 issue，把 `--version` 和报错原文贴上。
