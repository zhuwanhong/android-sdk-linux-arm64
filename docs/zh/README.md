# android-sdk-linux-arm64

**Android SDK / NDK 的 ARM64 Linux 移植。**

Google 只为 `linux-x86_64` 发布 Android 的构建工具。这意味着 ARM64 Linux 机器——Ampere、Graviton、树莓派、各家云上最便宜的那批实例，以及跑 Linux 的 ARM 笔记本——**编不了 Android 应用**。

源码是开源的（AOSP + LLVM）。缺的只是有人去编。

这个项目就是去编，并且把产物做成能直接解压到 `$ANDROID_HOME` 用的东西。

> **想知道「我在 mac / x86 上做的那件事，这儿能不能做」？**
> → **[docs/PARITY.md](PARITY.md)** —— 按**场景**列（不是按工具列），
> 每一行挂一条能自己跑的命令；⚠️ 和 ❌ 都写明缺什么、替代方案是什么。
> 机器可读的同一份在 [docs/parity.json](../parity.json)，
> `tools/check-parity.sh` 保证两份不走散。
>
> **只想用、不想知道怎么编出来的？** → [docs/INSTALL.md](INSTALL.md)

**状态**：**M1 的验收标准已经达到**——`tests/` 下两个样例工程都在 ARM64 Linux 上
编出了 APK，并在真机上跑通。`aapt2`、`zipalign` 都是自己编的了；
**host 工具链也不再是薄壳**——`tools/build-llvm.sh` 从 Google 的源码 pin
（`d8003a45`）编出了 clang 18.0.2，在真 ARM64 机器上 `--verify` 六步全绿，
其中包括跟官方 x86_64 二进制**逐字节相同**的目标码比对。见「里程碑」一节。

---

## 一、先自己确认问题真实存在

以下每一条都可以在几分钟内复现。**别信这份 README，自己跑一遍**——版本会变，Google 随时可能补上 ARM 构建（那样这个项目就没必要了，也是好事）。

一条命令跑完全部：

```bash
tools/verify-claims.sh
```

下面是它在做什么，以及为什么。

### 1.1 Google 的仓库里没有 ARM Linux 的包

```bash
curl -sO https://dl.google.com/android/repository/repository2-3.xml
python3 - <<'PY'
import re, collections
x = open("repository2-3.xml", encoding="utf8", errors="replace").read()
pairs = re.findall(r'<host-os>([^<]*)</host-os>\s*<host-arch>([^<]*)</host-arch>', x)
for (os_, arch), n in collections.Counter(pairs).most_common():
    print(f"{n:5}  {os_:8} {arch}")
PY
```

写这份文档时的输出：

| host-os | host-arch | archive 数 |
|---|---|---|
| linux | x64 | 61 |
| macosx | x64 | 61 |
| macosx | **aarch64** | **58** |
| windows | x64 | 61 |
| windows | x86 | 18 |
| **linux** | **aarch64** | **0** |

macOS 有 58 个 aarch64 archive（35 个包，Apple Silicon）。**Linux ARM 一个都没有。**

> 上面这个正则只匹配 `host-arch` 紧跟在 `host-os` 后面的条目，会漏掉约 500 个
> `host-arch` 缺省的历史条目（那些其实都是 x86_64）。结论不受影响，但要严谨的话
> 用 `tools/verify-claims.sh`——它按 `<archive>` 元素解析，并且额外扫一遍全部
> 854 个下载 URL 确认没有 linux + arm64 的漏网之鱼。

> Google 已经为 macOS 编了 ARM 版，**说明工具链本身完全能编到 ARM**。没给 Linux ARM 出包是分发决策，不是技术限制。

### 1.2 缺的到底是什么：只有原生二进制

SDK 里绝大部分是 Java（`.jar`）或 shell 脚本，跟 CPU 架构无关。真正卡住的是这些 ELF：

```
build-tools/<ver>/    aapt  aapt2  aidl  bcc_compat  dexdump  llvm-rs-cc  split-select  zipalign
platform-tools/       adb  etc1tool  fastboot  hprof-conv  make_f2fs  make_f2fs_casefold  mke2fs  sqlite3
ndk/<ver>/toolchains/llvm/prebuilt/linux-x86_64/    clang 及整套 LLVM
```

**而 `d8` / `r8` / `apksigner` 是 shell 脚本 + jar，`android.jar` 是纯 Java——这些原样就能在 ARM 上跑。**

自己确认：

```bash
find $ANDROID_HOME/build-tools $ANDROID_HOME/platform-tools -maxdepth 2 -type f \
  -exec sh -c 'file -b "$1" | grep -q ELF && echo "$1"' _ {} \;
file $ANDROID_HOME/build-tools/*/d8     # → shell script，不是 ELF
```

### 1.3 许可证：源码开源，是分发选择不是法律限制

NDK 自带的 `NOTICE`（约一万行）里以 Apache、BSD、GPL、MIT、LLVM/UIUC 为主。
`aapt2` / `zipalign` / `adb` 都出自 AOSP，Apache 2.0。LLVM 是 Apache 2.0 with LLVM Exception。

旁证：**Debian/Ubuntu 自己就发 `aapt` 和 `adb` 的 arm64 包**（见 `packages.ubuntu.com/noble/aapt`）。别人已经从源码编出过 ARM 版，只是零散、不成体系、不覆盖 aapt2 和 NDK。

---

## 二、关键结构洞察：NDK 的移植面比想象中小

**NDK 里跟 host 架构有关的只有四个目录，其中一个占了 97% 的体量。**

```
ndk/<ver>/
├── build/            纯脚本（cmake / ndk-build），跟架构无关
├── meta/             json 元数据
├── sources/          第三方源码
├── prebuilt/linux-x86_64/         8 MB   make / yasm / ndk-stack，**要重编**
├── shader-tools/linux-x86_64/    19 MB   glslc / spirv-*，**要重编**
├── simpleperf/bin/linux/         11 MB   profiler，**要重编**
└── toolchains/llvm/prebuilt/
    └── linux-x86_64/         1896 MB  ← 大头，占要重编那 1187 MB 的 97%
        ├── bin/ + lib/*.so 等  1149 MB  ← clang / lld / llvm-*，**要重编**
        ├── lib/clang/<ver>/     603 MB  ← compiler-rt + 编译器内建头文件，
        │                                   全是目标架构内容，**跟 host 无关，原样搬**
        └── sysroot/             144 MB  ← 目标头文件 + 目标库，**跟 host 无关，原样搬**
```

`sysroot/usr/lib/` 底下是 `aarch64-linux-android/`、`arm-linux-androideabi/`、`x86_64-linux-android/` 这些**目标**架构目录——它们描述的是手机，不是你的开发机。确认：

```bash
file $ANDROID_HOME/ndk/*/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/*/libc.so
# → ELF 64-bit LSB shared object, ARM aarch64     ← 给手机的，跟 host 无关
```

**所以任务是「换掉 host 工具链，保留 sysroot」，不是「重编整个 NDK」。**
这把工作量从「移植整个 NDK」缩到「为 aarch64 host 构建一套 LLVM，然后按 NDK 的目录约定摆好」。

> 另外三个目录别漏掉，尤其 `prebuilt/<host>/bin/make`——`ndk-build` 就是靠它跑的。
> `shader-tools`（Vulkan shader 编译）和 `simpleperf`（profiler）不影响编 APK，可以排到 M2 之后。
> 四个目录的体量是在一台 aarch64 Linux 机器上、拿 r27.1 的 **Linux 包**实测的。
> 会随版本变——`tools/verify-claims.sh` 会在你自己的机器上逐个目录重新数一遍，
> 并把 toolchains/llvm 拆成「要重编 / 原样搬」两部分。
>
> **「原样搬」的不止 sysroot。** `lib/clang/<ver>/` 那个 resource dir 里是
> 各目标架构的 compiler-rt、编译器内建头文件，和两个脚本（`asan_device_setup`
> 是 shell，`hwasan_symbolize` 是 python）——**一个 host 二进制都没有**，
> 跟 sysroot 是同一类。上面的拆分是在 aarch64 Linux 真机上实测的。
>
> 把 resource dir 算进「原样搬」之后，**要重编的总量是 1187 MB**
> （1149 + 8 + 19 + 11），而不是 1790 MB。少掉整整三分之一。

### host tag 只在几个文件里写死

```bash
grep -rl "linux-x86_64" $ANDROID_HOME/ndk/*/build $ANDROID_HOME/ndk/*/meta
```

r27.1 上是这几个（数量随 NDK 版本变）：

```
build/cmake/android.toolchain.cmake
build/cmake/android-legacy.toolchain.cmake
build/tools/make_standalone_toolchain.py
build/tools/ndk_bin_common.sh
build/ndk-build.cmd
```

（`ndk-build.cmd` 在 Linux 包里也有——Google 就是这么打的包，不用管它。）

> ⚠️ **这个 grep 是不够的，别拿它当全集。** 它只找字面量 `linux-x86_64`，
> 而最要命的一处是**拼出来的**：`build/core/init.mk` 里
> `HOST_TAG64 := $(HOST_OS_BASE)-$(HOST_ARCH64)`，`HOST_ARCH64` 无条件写死
> `x86_64`。这一处才是 `ndk-build` 真正编东西时决定用哪个 clang 的地方。
> 它是在真 ARM64 机器上撞出来的，读代码 grep 没抓到——见下面第四条。

**两条独立的路径，两处都要改。**

CMake 那条：`android.toolchain.cmake` 连 host CPU 都不判。

```cmake
if(CMAKE_HOST_SYSTEM_NAME STREQUAL Linux)
  set(ANDROID_HOST_TAG linux-x86_64)   # 直接写死
```

`ndk-build` 那条：`ndk_bin_common.sh` 反而**不写死**，它按 `uname -m` 判——
但 case 里没有 aarch64 分支，直接落到 `*)` 报错退出。

```bash
HOST_ARCH=$(uname -m)
case $HOST_ARCH in
  arm64) HOST_ARCH=arm64;;
  i?86) HOST_ARCH=x86;;
  x86_64|amd64) HOST_ARCH=x86_64;;
  *) echo "ERROR: Unknown host CPU architecture: $HOST_ARCH"
     exit 1                            # ← aarch64 走到这里
esac
```

还有第三条：`build/tools/make_standalone_toolchain.py` 的 `get_host_tag_or_die()`
只看 `sys.platform`，在 aarch64 上**不报错**，直接返回 `linux-x86_64`。
（那个工具 r19 起已废弃，不在 M1 路径上，但错的 tag 还是错的。）

第四条，也是唯一一条**不是读代码、是在真机上撞出来的**：
`build/core/init.mk`。前三条改完，`ndk-build` 能跑起来了，但真去编一个 `.c`
文件时报的是

```
.../toolchains/llvm/prebuilt/linux-x86_64/bin/clang: 1: Syntax error: "(" unexpected
```

路径还是 `linux-x86_64`。那句 `Syntax error` 也不是编译错误——是 shell exec
一个 x86_64 ELF 失败后，退回去把二进制当 shell 脚本解释了。

原因是 `ndk-build` 有**两条互不相干**的求 tag 路径：

| | 算出来的 tag 用在哪 |
|---|---|
| `build/tools/ndk_bin_common.sh` | 找 python / make 这些辅助程序 |
| `build/core/init.mk` | 算 `HOST_TAG64` → `TOOLCHAIN_ROOT` → **决定用哪个 clang** |

只改前者，`ndk-build --version` 会好看地打印出 GNU Make 的版本，让你以为成了。
一编东西就露馅。

**第一个代码改动就在这四处**：各加一个 aarch64 分支。补丁已经写好了：

```bash
tools/patch-ndk.sh          # 打
tools/verify-claims.sh      # 验：五处 BLOCK 应该都变 PASS
```

见 [`patches/ndk/`](../../patches/ndk/)。注意这些补丁只让 NDK **认得**
`linux-aarch64`，工具链本身还得编——那是 M1。

---

## 三、已有的先例

**先说清楚一件事：现有的 aapt2 先例，编出来的全是给 Android 跑的，不是给 ARM64 Linux 跑的。**

「ARM64」这个词把两件不同的事盖住了：

| | 目标 | libc | 跑在哪 |
|---|---|---|---|
| 现有先例做的 | `arm64-v8a`（Android ABI） | bionic | 手机 / Termux |
| **这个项目要的** | `aarch64` + Linux | **glibc** | **Ampere / Graviton / 树莓派 / ARM 笔记本** |

| 项目 | 目标 | 说明 |
|---|---|---|
| [`ReVanced/aapt2`](https://github.com/ReVanced/aapt2) | Android | 用 CMake **独立编译 aapt2**，不需要整套 AOSP checkout。活跃维护。**先读它是怎么绕开 soong 的。** |
| [`lzhiyong/android-sdk-tools`](https://github.com/lzhiyong/android-sdk-tools) | Android | 上面那个的源头。已经 CMake 化了 `aapt aapt2 aidl zipalign adb fastboot`——**几乎覆盖 M1–M3 的整张工具单**。但 README 明说「只适用于用 Android NDK 编译，不适用于其他 Linux 发行版」。 |
| [`arriRgb31/aapt2-termux`](https://github.com/arriRgb31/aapt2-termux) | Android（Termux） | 在 Termux 里就地编 aapt2 |
| [`zangbivo/aapt2`](https://github.com/zangbivo/aapt2) | Android | 连 zipalign 一起编，参考的也是 lzhiyong |
| Debian / Ubuntu 的 `aapt`、`adb` 包 | **Linux glibc** | **表里唯一真正对口的先例。** 已有 arm64 构建规则，可复用 |

**为什么 `ReVanced/aapt2` 仍然值得先读**：aapt2 在 AOSP 里靠 soong 构建，完整 checkout 200+ GB。他们把它拆成了 18 个 pin 在 `platform-tools-35.0.2` 的 AOSP 子模块 + 约 730 行 CMake + 3 个补丁。**「怎么绕开 soong」这套思路直接可用**——要换的是编译目标：去掉 `-DCMAKE_TOOLCHAIN_FILE=android.toolchain.cmake`，在 ARM64 机器上原生编，然后处理 bionic → glibc 的差异（`libcutils` / `libselinux` / `libprocessgroup` 是风险最大的三块）。

> ⚠️ 别直接用这些项目的**产物**。要自己编、自己验。理由见第五节。

### 「静态二进制能不能在 glibc 上跑」——验过了，成立

上面那张表说这些项目编的是 Android/bionic 的东西。但它们的 aarch64 产物是
`-static` 链的，**静态 ELF 没有动态链接器依赖**，所以「编给 Android」对它们
不构成障碍。在一台 aarch64 Ubuntu 机器上实测（lzhiyong 35.0.2 的 release）：

| 验的 | 结果 |
|---|---|
| `file aapt2` | `ELF 64-bit LSB executable, ARM aarch64, statically linked`，无 INTERP 段 |
| `aapt2 version` | `Android Asset Packaging Tool (aapt) 2.19-` |
| `aapt2 compile` 一个真 `strings.xml` | 出 `values_strings.arsc.flat`，204 字节 |
| `aapt2 link` + `android-36/android.jar` | 出 APK，1143 字节 |
| `aapt2 dump badging` | `package: name='com.example.probe'` ← **第五节写的那条验收标准** |
| `zipalign -c -v 4` | `Verification successful`，exit 0 |
| `adb version` | 认出宿主：`Running on Linux 6.17.0-1020-oracle (aarch64)` |

**所以 aapt2 / zipalign 这条线的构建配方是可行的**，不必为 glibc 重做 retarget。
第六节原先写「去掉 toolchain file，在 ARM64 上原生编」，是按「必须链 glibc」推的——
现在看，那不是必须的，静态链是一条更省事的路。

**边界，别外推：**

- 证明的是**这几个工具在做这几件事时能跑**，不是「静态 bionic 二进制在 glibc 上普遍能跑」。
- 静态 bionic 最容易出问题的地方是 DNS 解析、locale、用户/组查询、`dlopen`。
  aapt2 和 zipalign 基本只碰文件 I/O，正好避开了这些。
- `adb` 的**设备那条路已经验了，而且失败了**——见下。
- `aidl` / `dexdump` / `split-select` / `fastboot` 等**一个都没验**，只知道它们出自同一套构建。
- 第五节那条仍然算数：**别用别人的产物，要自己编。** 变的是「配方可行」
  从未知变成了已知——这是省掉的最大一块不确定性。

**已经自己编出来了**：

```bash
tools/build-aapt2.sh          # 取源码 + 编 + 验
```

在 4 核 aarch64 上编完 962 个目标，产物 95 MB，strip 后 4.7 MB。
用它重跑 `tests/hello-jvm`，出来的 APK 跟用别人那份编的**大小完全一致**
（12766 字节）——两条链路产出等价。

编的过程撞了三个障碍，**没有一个来自 LLVM 那 71 个补丁**：

| 报错 | 根因 |
|---|---|
| `unable to find library -lgcc` | rtlib / unwindlib 的内建默认值（见上表） |
| 一堆 `std::exception` / `_Unwind_*` 未定义 | unwindlib 的内建默认值（见上表）。**这一行原来写的是「stdlib 的内建默认值」，错了**——量下来发行版 clang++ 对 android 三元组默认发的就是 `-lc++`，详见第四节 |
| `__cxxabiv1::__class_type_info` 未定义 | 上游 `cmake/aapt2.cmake:199` 显式链了 `c++_static`，却没链它的另一半 `c++abi`；上游能蒙混过关是因为 NDK 的 clang 会另外加 `-lc++`（那是链接脚本 `INPUT(-lc++_static -lc++abi)`） |

**问题始终出在「谁替你补默认值」上，不在编译器的能力。**
这也是薄壳方案能成立的根本原因。

**不需要 x86_64 机器，也不需要 qemu。** 一度以为需要：上游的 `build.sh` 靠
`android.toolchain.cmake` 找 `prebuilt/<host-tag>/bin/clang`，而 aarch64 上
那个目录本来不存在——这是个死循环（要编 aapt2 得先有 NDK 工具链，而工具链
正是缺的那个）。`tools/make-shim-toolchain.sh` 把那个目录建出来之后，前提就没了。
**为 M1 的 NDK 那半做的东西，正好解开了 aapt2 这半的死结。**

#### 已知的一处失败：adb 的守护进程

`adb version` 能跑，但 `adb devices` 起不来：

```
adb_auth_inotify_init...
fdsan: failed to exchange ownership of file descriptor: fd 10 is owned by
       unique_fd 0x..., was expected to be unowned
* failed to start daemon
```

`fdsan` 是 bionic 的文件描述符哨兵。`version` 不启动守护进程所以没事；
一起守护进程就要走 inotify 那条路，fdsan 检测到 fd 所有权不一致就 abort。

**这是静态 bionic 二进制在 glibc Linux 上的第一个真实边界。** 它印证了上面
那条警告不是客套：aapt2 / zipalign 基本只碰文件 I/O，所以没事；adb 要管
fd 生命周期、inotify、socket，就撞上了 bionic 对运行环境的假设。

对这个项目的影响不大，因为 **Debian/Ubuntu 本来就发原生 glibc 的 arm64 `adb`**
（第 1.3 节那个旁证）：

```bash
sudo apt install -y adb
```

但它是一个明确的提醒：**「静态二进制能跑」这个结论必须逐个工具去验，
不能整套外推。**

---

## 四、里程碑

按「能解锁多少」排序，不是按难度。

> **这一节的分法需要重估。** M1 / M2 / M3 排成三级，前提是三批工具各自要单独攻。
> 但实测下来，`aapt2 aapt aidl dexdump split-select zipalign` 加
> `adb fastboot etc1tool hprof-conv mke2fs make_f2fs sqlite3`——**M1 到 M3 的整张单子**——
> 出自同一套 CMake 构建（见第三节）。那它们就不是三个里程碑，是一个里程碑的附带产物。
>
> 照这个证据，**真正没人做过的只剩 NDK 那 1752 MB**。下面还没改，因为每个工具
> 仍然欠一条自己的验收测试（第五节第 5 条），单子长短和难度大小是两回事。

### M1 · 能出一个 APK（最小闭环）

编出 ARM64 版的 `aapt2`、`zipalign`，以及 NDK 的 host 工具链。

NDK 那半的产出清单——**不只是 clang**。下面这张表是在真 ARM64 机器上打完补丁、
一项项跑 `ndk-build` 撞出来的，不是读代码列的：

| 要放到哪 | 里面是什么 | 缺了会怎样 |
|---|---|---|
| `toolchains/llvm/prebuilt/linux-aarch64/bin/` | clang / lld / llvm-* | `No such file or directory`，Error 127 |
| `toolchains/llvm/prebuilt/linux-aarch64/python3/` | NDK 自带的 python3 | **静默降级**成裸 `python`——Ubuntu 22.04+ 没这个名字，`$(shell …)` 全返回空，`APP_PLATFORM` 之类悄悄取默认值 |
| `toolchains/llvm/prebuilt/linux-aarch64/sysroot/` | 从 `linux-x86_64` **原样搬** | 找不到目标头文件和库 |
| `prebuilt/linux-aarch64/bin/` | make / yasm / ndk-stack | 退回系统 `make`，多数发行版都有，**能用**——所以这项优先级最低 |

在 ARM64 机器上 `tools/verify-claims.sh` 会逐项报缺哪个。
python 那项在编出来之前可以先绕过：`NDK_HOST_PYTHON=$(command -v python3) ndk-build …`
（**编出来之后就别再传了**。`tests/hello-native/build.sh` 已经不传——传了就是拿系统的
python 把「工具链自不自足」盖住，而那正是要验的。真缺 python 不会静默降级：
`patches/ndk/0005` 让 `init.mk` 直接 `$(error)`。）

#### 一条不用编 LLVM 的快速通道（实测可行）

上表默认「clang 得自己编」。但 **Android 目标支持在上游 LLVM 里就有**，
发行版自带的 clang 未必不能用。在 Ubuntu 24.04 / aarch64 上实测（系统 clang 18.1.3，
NDK r27.1 的 clang 是 18.0.2——同一个大版本）：

```bash
NDKP=$ANDROID_HOME/ndk/27.1.12297006/toolchains/llvm/prebuilt/linux-x86_64
clang --target=aarch64-linux-android21       --sysroot=$NDKP/sysroot       -resource-dir=$NDKP/lib/clang/18       -rtlib=compiler-rt -unwindlib=libunwind       -L$NDKP/lib/clang/18/lib/linux/aarch64       -fuse-ld=lld -shared -o libhello.so hello.c
```

出来是 `ELF ARM aarch64 shared object`，`NEEDED` 是 `libdl.so` / `libc.so`（bionic 的）。
换 `clang++` 加 `-static-libstdc++` 编 C++（`std::string` + `std::vector`）同样通过。

**关键在于差别是什么。** 每次报错都不去猜，而是问 NDK 自己的 clang 要链接命令
（`clang -### --target=aarch64-linux-android21 -shared`），拿它的答案对照。
三处差异全部是**编译时的内建默认值**，没有一处需要那 71 个补丁：

| 报错 | 根因 | 补法 |
|---|---|---|
| `unable to find library -lgcc` | 发行版的 clang 把 `CLANG_DEFAULT_RTLIB` 烤成了 `libgcc` | `-rtlib=platform` |
| 一堆 `_Unwind_*` 未定义 | 同上，`CLANG_DEFAULT_UNWINDLIB` | `-unwindlib=platform` |

**这张表原来写反了，2026-08 重新量过。** 原来写的是「NDK clang 编译时设了
`CLANG_DEFAULT_RTLIB=compiler-rt`」——方向正好相反：

* **上游 clang 的 driver 自己就认识 Android。**
  `clang/lib/Driver/ToolChains/Linux.cpp:339` `isAndroid()` → `RLT_CompilerRT`；
  `:351` `isAndroid()` → `CST_Libcxx`；`ToolChain.cpp` 里 rtlib 是 compiler-rt
  且 `isAndroid()` → `UNW_CompilerRT`。这三处在 Google 那个 pin
  （`d8003a45`）和上游 `llvmorg-18.1.3` 里**逐字一样**，diff 过。
* **Google 一个都没设。** `toolchain/llvm_android` 在对应版本（commit `7aecce1`,
  "Update stable branch to clang-r522817"）的 `base_builders.py` 里只有
  `CLANG_DEFAULT_LINKER=lld` 和 `CLANG_DEFAULT_OBJCOPY=llvm-objcopy`，
  搜遍全仓库没有 `CLANG_DEFAULT_RTLIB` / `UNWINDLIB` / `CXX_STDLIB`。
* **设了的是发行版。** Ubuntu 的 clang 包把 rtlib 和 unwindlib 的默认值烤死成
  libgcc，**盖掉了** driver 里那三行 Android 判断。判别法很干净：`platform`
  这个值的意思就是「按 driver 的判断来」，加上 `-rtlib=platform` 之后发行版
  clang 立刻发出 `libclang_rt.builtins-aarch64-android.a`。

所以自己编 LLVM 时，这三个变量**必须留空**——设了反而是错的。
`tools/build-llvm.sh` 在 cmake 配置完会当场检查 `CMakeCache.txt` 里这三项是不是空的。

**第三行删掉了，它是错的。** 原来写「发行版 clang 默认 `-stdlib=libstdc++`，
发出 `-lstdc++` 链上桩」——量下来不是：发行版 `clang++` 对 android 三元组
默认发的就是 `-lc++`（`CLANG_DEFAULT_CXX_STDLIB` 发行版没动，driver 的
Android 判断生效）。当时那一堆未定义符号数出来是 **8 个，全是 `_Unwind_*`**
（`_Unwind_Resume`、`_Unwind_RaiseException` …），缺的是 unwinder，不是 stdlib
选错了。薄壳里那句 `-stdlib=libc++` 是**无害的空操作**，留着不碍事。

（sysroot 里的 `libstdc++.a` 确实是个只含 `__cxa_guard_*` 和
`__cxa_pure_virtual` 的桩，`libc++.a` 确实是链接脚本 `INPUT(-lc++_static -lc++abi)`
——这两条是真的，只是跟上面那个报错没关系。显式传 `-static-libstdc++` 才会
踩到它们。）

补上那两个 `platform` 之后，发行版 clang 18.1.3 和 NDK clang 18.0.2 的
`-###` 输出**只差三处**（归一化掉路径和临时文件名后逐 token 比）：

| 差在哪 | 谁多的 | 是什么 |
|---|---|---|
| `-fskip-odr-check-in-gmf` | 发行版 | 18.1.x 才进的 cherry-pick，Google 的 18.0.2 pin 里还没有 |
| `-target-feature +fp-armv8` | 发行版 | 多一项，且 target-feature 的顺序也不同 |
| `--build-id` | 发行版 | Debian 给 clang 打的默认值，NDK 那份不发 |

`--build-id` 那条后来在真机上拿到了实物证据。同一份 `make_f2fs_casefold`
源码、同一个配方，两台机器编出来差 **64 字节**：

| 编它的 host 工具链 | 产物 | `file` 说 |
|---|---|---|
| 容器里：NDK 自带的官方 clang（x86_64 host） | 650688 字节 | `statically linked, stripped` |
| 真机上：薄壳（Ubuntu clang 18.1.3） | 650752 字节 | `BuildID[xxHash]=…, stripped` |

差的正好是那一节 `.note.gnu.build-id`。**这对 M4 有实际影响**：拿薄壳编出来的
产物和拿真 NDK clang 编出来的不是同一串字节，没法互相校验。等
`tools/build-llvm.sh` 的产物顶上去，这个差别就没了。

> **别把这条推广到 `ndk-build`。** 我自己照着它推错过一次：`ndk-build` 和
> NDK 的 CMake toolchain file 都**无条件**加 `-Wl,--build-id=sha1`
> （`build/core/build-binary.mk:442`、`build/cmake/flags.cmake:69`），
> 所以走那两条路编出来的 `.so` **两种工具链都有 build-id**，换了也不会消失。
> 上面这个差别只出现在**本仓库这套 cmake 配方**里——实测它的链接命令里
> 根本没有 `--build-id`（`grep -o '\-Wl,--build-id[^ ]*' build.ninja` 为空），
> 所以有没有 build-id 完全由编译器的内建默认值决定。
>
> 反过来，`build-id` 的**算法**倒是个好判据：`BuildID[sha1]`（20 字节）说明
> `--build-id=sha1` 生效了；`BuildID[xxHash]`（8 字节）是 lld 的默认值，
> 说明那个 flag 没到，产物是走另一条路编的。

而**同一份 C 源码编出来的目标码，去掉 `.comment` 段后两边逐字节相同**
（`.comment` 里是 `CLANG_VENDOR` 字符串，本来就不一样）。也就是说：
薄壳在「生成什么代码」这件事上跟官方没有差别，差别只在驱动传给
`-cc1` 和 `ld.lld` 的那几个 flag 上。这也是 `tools/build-llvm.sh --verify`
第 3、4 步在验的两件事。

（`-z max-page-size=4096`、`--fix-cortex-a53-843419`、`--hash-style=both`
这组 Android 专用链接器参数**不用补**——driver 按 android 三元组自动就发，
发行版和官方都发。这句话原来写的是「目前没加，做正式产物时要补齐」，也是错的。）

照这个思路，`prebuilt/linux-aarch64/` 可以先做成一层薄壳：包装脚本
+ 从 x86_64 那份借来的 `sysroot/` 和 `lib/clang/<ver>/`。**1149 MB 的重编
变成几个软链和一批包装脚本。**

已经做出来了：

```bash
tools/make-shim-toolchain.sh          # 搭
tools/make-shim-toolchain.sh --remove # 拆
```

aarch64 Ubuntu 真机上的产出：2 个 clang 包装、122 个三元组前缀包装、
39 个软链到系统 LLVM 的工具。**`ndk-build` 用它完整编出了 `libhello.so`**——
ARM64 Linux 上第一次由 NDK 构建系统驱动的编译。

系统 LLVM 里没有、因此缺的 18 个：`clang-format` `clangd` `clang-tidy`
`lldb` `llvm-bolt` `scan-build` `yasm` 等。**编 app 一样不缺**——都是开发／调试
／分析工具；`yasm` 只在编 x86 目标的汇编时用得上。

**边界，这条通道不是最终形态：**

- 只验到「编得出、链得上」。**没有在真机或模拟器上跑过产物**，「能链接」不等于「行为正确」。
- 异常抛出/捕获没有实际执行过（libunwind 链上了，但没被触发）；RTTI、线程、
  sanitizer、LTO、以及 ndk-build / CMake 的完整集成都没验。
- 版本是错开的：系统 18.1.3 vs Google 18.0.2 + 71 补丁。第四节「不做什么」
  写着**产物必须和官方 x86_64 版行为一致**，这条通道达不到那个标准。
- 它把「自带工具链」换成了「依赖用户发行版的 clang」。发行版没有合适版本就用不了。

所以它是 **M1 的快速通道**，能让 `tests/hello-native/` 早早跑起来；
自带工具链的正式版本仍然要编 LLVM，只是可以往后排。

#### 正式版本：`tools/build-llvm.sh`

薄壳那四条边界，前三条都是同一句话的推论：**它不是同一份编译器**。
要去掉它们只有一条路——把 Google 那份编出来。配方写好了。

| | |
|---|---|
| 源码 | `android.googlesource.com/toolchain/llvm-project`，分支 `llvm-r522817`，HEAD = `d8003a456d14a3deb8054cdaa529ffbf02d9b262` |
| 出处 | **问 NDK 自己的 clang 要**：`bin/clang --version` 括号里印的就是它自己是从哪个 commit 编出来的。不猜。 |
| cmake flags | `toolchain/llvm_android` 的 `build.py`（对应版本是 commit `7aecce1`）。它在这里的地位等同于别的工具那边的 `Android.bp`。 |
| 那 70 多个补丁 | **不用打。** `llvm_android/patches/` 是「怎么造出这个分支」的配方，分支上的代码已经是打完的结果——clang 报的就是这个 commit。再打一遍是错的。 |

有意跟 Google 不一样的地方，一处不藏：

| 差别 | 为什么 | 代价 |
|---|---|---|
| 不做 `+pgo` `+bolt` `+lto` `+mlgo` | 要 profile 数据、要 BOLT 跑 instrument 再优化、要两阶段 LTO，是几倍机时 | 编译器**自己**跑得慢些、大些。**不影响它生成什么代码**——这句话由 `--verify` 第 4 步在验，不是嘴上说的 |
| 只编 `clang;lld` | Google 还编 `clang-tools-extra;polly;bolt(;lldb)` | 少 `clangd` / `clang-tidy` / `clang-format` / `llvm-bolt` / `lldb`。编 app 不缺，跟薄壳缺的那 18 个是同一类 |
| `LLVM_ENABLE_LIBCXX=OFF` + `-static-libstdc++` | Google 用他们 stage1 编出来的 libc++，我们没有 stage1 | 无。官方 `clang-18` 的 `NEEDED` 里本来也没有 libc++/libstdc++（只有 `libgcc_s` `libc` `libz` 等），静态链进去这一点是对齐的 |
| `LLVM_INCLUDE_TESTS=OFF` | 省掉 gtest 和一大堆 unittest | 跑不了 `check-clang` |
| `LLVM_BUILD_LLVM_DYLIB=OFF` | Google 设 ON，但 NDK 的 `lib/` 里根本没有 `libLLVM*.so`（数过），打包时没带 | 省一次大链接 |

> ⚠️ **原来还有第六处，是错的。** `LLVM_ENABLE_ZSTD=OFF` —— 当初为了少装一个
> 包设的，判断成「无害」。不是：**NDK sysroot 里的 `libc.a` 用 ZSTD 压了
> debug 段**，lld 不带 zstd 支持就链不了任何静态的 Android 二进制：
>
> ```
> ld.lld: error: libc.a(malloc_limit.o):(.debug_str_offsets) is compressed
> with ELFCOMPRESS_ZSTD, but lld is not built with zstd support
> ```
>
> Google 的 `base_builders.py:752` 写着 `LLVM_ENABLE_ZSTD=FORCE_ON` +
> `LLVM_USE_STATIC_ZSTD=ON`。**照抄的地方别自作主张。**
> 现在要 `libzstd-dev`（`--fetch` 会查，静态链所以要 `.a`）。
>
> 这个洞是拿自己编的工具链编 `adb` 时在真机上炸出来的。第一反应是「x86 上
> 结构性照不出来」（那边编 Android 目标用的是 NDK 自带的官方 lld）——
> **随手拿容器里那份 `ZSTD=OFF` 的产物一试，当场复现。是测试写漏了，
> 不是环境的限制。** 真正的原因是 `--verify` 第 6 步只链了一个 `.so`，
> 动态链碰不到 `libc.a`。现在第 6 步是两条，第二条静态链一个可执行文件；
> 修完重编，两条都绿。
>
> **少一条测试就是少一条，别拿「环境不同」当解释。**

`sysroot/` 和 `lib/clang/18/` **不编**，从 NDK 自带的 `linux-x86_64` 那份拷过来。
那两块是**目标产物**（bionic 的头文件和库、compiler-rt 的 android 运行时），
跟 host 是什么架构无关——薄壳早就靠软链这两块跑通过 `ndk-build`。
拷而不是软链，是为了这份 `prebuilt/` 能单独打包分发（M4 要用）。

**验收怎么设计的，值得单说。**

官方的 `linux-x86_64/bin/clang` **在 ARM64 上跑不了**（exit 126，跟 `aapt2`
那次一模一样）。所以「跟官方对照」这件事，参照物不能现跑，只能是**事先录好的
黄金值**（第五节第 6 条）。录了两样：

1. **驱动打算干什么。** `clang++ --target=aarch64-linux-android21 -### g.cpp -o g`
   的两条命令行（`-cc1` 一条、`ld.lld` 一条），归一化掉工具链根目录、当前目录、
   临时 `.o` 名，得到 103 个 token。逐 token diff。
2. **它真编出来的字节。** 一份固定的 `golden.c`（哈希、向量点积、循环归约、
   switch、递归、常量除法），`-O2 -c`，去掉 `.comment` 段（那里面是
   `CLANG_VENDOR`，本来就不一样）后取 sha256。aarch64 和 armv7a 各一个。

第 2 条同时就是在验上面那句「不做 PGO/BOLT/LTO/MLGO 不影响生成的代码」——
对不上就说明那句话是错的。

**这套测试自己也验过了，两头都试：**

- 把 `LLVM_OUT` 指到**官方那棵树**跑 `--verify`：六步全绿。黄金值就是从它录的，
  它必须全绿，否则是测试写错了。
- 把 `LLVM_OUT` 指到**薄壳**跑：第 2 步就红（`Ubuntu clang version 18.1.3`）。
  绕过版本这关单看第 3 步，比出 18 行差异，其中三行是真差别——就是上面那张
  「只差三处」的表：`+fp-armv8`、`-fskip-odr-check-in-gmf`、`--build-id`。

第 1 步照老规矩是**一条必须失败的测试**：拿它编一份故意写错的 C，编过了就当场
判失败——不然后面五步测的根本不是「编译」这件事。

第 5 步是**这次学到最多的一步**，值得单说：

> 第一版第 5 步是我手写的九个工具名，九个全在，绿。
> 但装出来实际漏了十几个（`llvm-config` `llvm-link` `llvm-as` `llvm-dwarfdump`
> `llvm-lipo` `dsymutil` …，连 `llvm-readelf -> llvm-readobj` 这种符号链接
> 都没装，而 build 目录里明明有）。**手写的清单只能证明清单里那几个在。**
> 改成逐个对官方那份 `prebuilt/*/bin/`，只允许一张写明理由的「知道没有」名单
> ——改完立刻又照出一个：`ld -> ld.lld`，Google 自己加的符号链接。
>
> 而那张名单第一版又踩了一次：名字和理由写在同一行用空格分，解析时从理由里
> 抠出了 `compiler-rt` 和 `2`（「见开头第 2 条」）两个不存在的条目。今天不影响
> 结果，但**机制不成立**——理由里只要写到某个真实工具名，就等于对那个名字
> 静默放行。改成一行一个名字、`#` 之后是理由，**再加一条自检**：名单里的每一项
> 都必须真的是官方 `bin/` 里的条目，否则当场判失败（塞一个假名字试过，会红）。
>
> 两次都是同一个形状的错：**放行名单比检查清单危险**，因为它的错误方向是静默的。

根因是 `LLVM_INSTALL_TOOLCHAIN_ONLY=ON`——我加它是为了少装点东西，它顺手把
NDK 实际带着的那十几个也挡在了 `install` 之外。改成装全套再裁。
顺带一个 cmake 的坑：**删掉 `-D` 不会让缓存变量变回默认值**，必须显式写 `=OFF`，
否则老 `build` 目录里还留着上一次的 `ON`。

### 实测代价（4 核，链接并行 2）

| | |
|---|---|
| `ninja` | **65 分钟** |
| 磁盘 | 源码 2.1 G + `build` 3.4 G + 装出来 1.8 G = **7.3 G** |
| 装出来 | `bin/` 703 M（已裁掉官方不带的 61 个、1.2 G）、`lib/clang` 603 M、`sysroot` 144 M |

**真 ARM64 机器上（4 核 Ampere / Ubuntu 24.04）`--verify` 六步全绿**，包括第 3 步
103 个 token 的驱动行为、第 4 步两个目标码哈希跟官方 x86_64 二进制逐字节相同。
也就是说：**「不做 PGO/BOLT/LTO/MLGO 不影响它生成什么代码」这句话在目标架构上
验住了**，不是推论。

**然后换进 NDK 跑了端到端**：删干净 `libs/` `obj/` `build/` 重来一遍，
`ndk-build → javac → d8 → aapt2 → zipalign → apksigner` 全程走通，出了签好名的
APK，`aapt2 dump badging` 读出的包名和 `minSdkVersion` 都对。

确认它**真的**是新工具链编的，用了三条互相独立的证据（`ndk-build` 是增量的，
换编译器不会让它失效，很容易拿到一个上一轮的旧产物就以为成了）：

| 证据 | 读数 |
|---|---|
| build-id 算法 | `NT_GNU_BUILD_ID` 长 `0x14` = 20 字节 = **SHA-1**，即 `ndk-build` 的 `-Wl,--build-id=sha1` 生效了；旧那份是 8 字节的 xxHash |
| 时间戳 | `clang-18` 装于 11:45:04，`.so` 编于 13:27:23 |
| 体积 | 4672 → 4816 字节，不是同一个二进制 |

**到这里，编 APK 这条路上已经没有别人的 host 二进制了**（`d8` / `apksigner`
是跟架构无关的 jar，`javac` 是系统 JDK）。

改配方之后不用重编：cmake 换 install 配置不触发重新编译，第二遍 `ninja` 实测
**269 条规则、0 分钟**，剩下的是装、裁、拷 `sysroot` 和 `lib/clang`。

裁掉的 61 个是 `opt` / `llc` / `bugpoint` / `clang-repl` / `llvm-lto` / `llvm-reduce`
这类**改 LLVM 自己**用的工具，NDK 一个都不带。判据仍然是官方那份有什么。

#### `python3/`：最后一处不自足，也补上了

官方那份带一整个 CPython。少了它 `ndk-build` 会**静默降级**成裸 `python`
（`patches/ndk/0005` 就是补这个的）。这一块原来是软链系统的——够用，但那样
这份 `prebuilt/` 没法单独打包分发。

`tools/build-python.sh` 编它。**版本不是凑的**：Google 自己不编 CPython
（`llvm_android` 里用的是 AOSP 的 `prebuilts/python`），所以权威是两样——
NDK 实际发的那份（3.11.4、`RPATH=$ORIGIN/../lib`、`lib-dynload` 69 个模块、
裁掉了 `test/` `idlelib` `tkinter` `config-*`），以及
`external/python/cpython3` 在 `platform-tools-35.0.2` 上**正好就是 3.11.4**。

> **踩到一个很值钱的坑：`$ORIGIN` 被 make 吃掉了。**
>
> `configure` 的 `LDFLAGS` 写成 `'-Wl,-rpath,$ORIGIN/../lib'`，那个 `$O`
> 被 make 当成自己的变量展开成空，产物里的 `RUNPATH` 变成 `RIGIN/../lib`。
> 于是 `bin/python3` 加载的是**系统那份** `libpython3.11.so.1.0`，
> 报出来的版本是系统的 3.11.15 而不是 3.11.4 ——
> **「自足」这个前提整个是假的，而它看起来完全正常。**
> 要写 `'\$$ORIGIN'`：穿过 bash 单引号、configure、make（`$$`→`$`）、
> make 调起的 sh（`\$`→`$`）四层。
>
> 抓住它的是 `--verify` 第 2 步的版本检查。
> **「自足」这件事必须被测，不能被声明** ——
> 所以 `build-llvm.sh --verify` 第 6.5 步的判据也从「文件在不在」改成
> **`sys.prefix` 在不在工具链内**：软链过去的系统 python 也能跑、也打得出版本号。

`--verify` 四步：红自检 / 版本 + `sys.prefix` + rpath / **扩展模块名单逐个对
NDK 那份**（少了算错，多了只提示）/ 真拿它跑 `ndk-build` 用到的那五个脚本。
第 3 步抓出过 `nis` 缺失（要 `libnsl-dev`）——CPython 的 `make` 对缺库
**只警告不报错**，所以 `--fetch` 现在会提前查那五个 `-dev` 包。

**2026-08-28 在真 ARM64 机器上跑通**：`build-llvm.sh --verify` 第 6.5 步报
「自带 CPython 3.11.4，`sys.prefix` 在工具链内 —— 自足」。

**验收**：`tests/` 下自带的两个样例工程，在 ARM64 Linux 上编出可安装的 APK。

#### 现在到哪了

**验收标准和产出都到了。**

> **2026-08-28：整条路上的 host 二进制全部换成自己编的，重跑了一遍端到端。**
> NDK 里的 `linux-aarch64` 换成 `tools/build-llvm.sh` 编的 clang 18.0.2（不再是
> 薄壳），删干净 `libs/ obj/ build/` 重来，两个样例工程都在同一台真机上跑起来：
>
> * `hello-native` —— `native ok: 64-bit, built Aug 28 2026`，`20 + 22 = 42`
> * `hello-jvm` —— `items = abc` 从 `strings.xml` 出来，文字是粉的说明
>   `color = #ffff3366` 真的解析并应用了
>
> **当天晚些时候 `adb` 也编出来了，又跑了一遍 `hello-native --install`，
> 这次是自己编的 `adb` 把 APK 推上去、起 Activity、拉回 logcat。**
>
> 也就是说：**从源码到手机上跑起来，整条链上的 host 二进制没有一个是别人的**
> —— clang、lld、aapt2、zipalign、adb 全是这台 ARM64 机器自己编的。
> 剩下借来的只有跟架构无关的东西（`d8` / `apksigner` 是 jar，`javac` 是系统 JDK）。

下面这一段是**换工具链之前**的记录，留着作对照——那时候原生库是薄壳编的：

**两个样例工程都在真机上跑通。** 在一台 aarch64 Ubuntu 云实例上：

```
ndk-build → javac → d8 → aapt2 link → zipalign → apksigner → adb install
```

`hello-native` 装进真手机，Activity 起来，JNI 函数返回
`native ok: 64-bit, built Aug 27 2026`，`20 + 22 = 42`。原生库是 NDK 的
host 工具链编的，**计算真的发生了**，不是「装上了」而已。

`hello-jvm` 走另一条路——`aapt2 link` 生成 `R.java`，`hello-native` 一步都没走到。
真机上显示 `hello from jvm` / `items = abc` / `color = #ffff3366`，
而且**文字是粉色渲染的**：那是 layout 里 `android:textColor="@color/accent"`
生效了。这比日志更硬——它证明 layout XML 被编译、链接、并在运行时正确 inflate，
不只是 R 常量解析成功。

**但 M1 的产出还差最后一块**：

| 缺什么 | 为什么算缺 |
|---|---|
| ~~`aapt2` 用的是别人的产物~~ | **已经自己编出来了** —— `tools/build-aapt2.sh`，962/962，strip 后 4.7 MB，`tests/hello-jvm` 已经用它跑通 |
| ~~`zipalign` 用的是别人的产物~~ | **也自己编出来了** —— `tools/build-zipalign.sh` + `cmake/zipalign.cmake`，strip 后 587 KB。上游那套 CMake 没有 zipalign 目标，照 AOSP 自己的 `build/tools/zipalign/Android.bp` 补的。**在 aarch64 真机上一次过**，`--verify` 的四条测试也在真机上跑过 |
| ~~host 工具链是**薄壳**，不是编出来的~~ | **也编出来了** —— `tools/build-llvm.sh`，真机上 `--verify` 六步全绿。薄壳留着，它仍是最快的上手路径 |

> **zipalign 那块有两条记录值得留着。**
>
> **一、源码不在上游那 18 个子模块里。** 它在 `platform/build` 的
> `build/tools/zipalign/`（不是 `frameworks/base`），`ZipFile.cpp` 还直接
> `#include "zopfli/deflate.h"`，要 `external/zopfli`。两棵树由脚本另取，
> pin 在跟上游子模块同一个 tag，每次 `--fetch` 自己对一遍，对不上就拦下——
> 混着版本编出来的东西没人知道是什么。**加下一个工具时，第一件事还是先确认
> 源码在哪棵树里**，别假定它在已经取下来的那些里面。
>
> **二、配方是先在一台 x86_64 上编通的。那一遍不算验收，但不白跑。**
> 产物是交叉编译出来的 `arm64-v8a` 二进制，host 架构不进产物——所以 x86 那遍
> 能证明「目标定义对、源码编得过、符号链得上」，把配方本身的错先筛掉了。
> 它证明不了 aarch64 host 那条腿：那边用的是**薄壳**（发行版 clang 18.1.3），
> 跟 Google 那份 18.0.2 的内建默认值不一样，aapt2 撞到的那几处障碍
> （上面「快速通道」那张表）全出在这个差别上，x86 一处都撞不到。
> 真机上后来一次过，说明**薄壳补默认值的做法对 zipalign 一样管用**——
> 它比 aapt2 简单，只多链了 `libzopfli`（12 个纯 C 文件）和 `libz`。

换句话说：**路走通了，别人的砖也快换完了，只剩工具链那一大块。**

这个项目的核心论断——ARM64 Linux 能构建并交付 Android 应用——到此不再是论断。
剩下的是把别人的砖换成自己的。

### M2 · 补齐 build-tools

第 1.2 节那张 ELF 清单里 `build-tools/` 那行，减掉已经自己编出来的 `aapt2` 和
`zipalign`，剩下四个：**`aapt`（v1）、`aidl`、`dexdump`、`split-select`**。
（`bcc_compat` / `llvm-rs-cc` 属于已废弃的 RenderScript——**先确认真有人需要，没有就跳过**。）

> `aapt`（v1）以前漏在这张单子外面——它在 1.2 的 ELF 清单里，M2 却没列。
> Gradle 早就不用它了，但 apktool 那类第三方工具还在调。

**四个的成本差很多。** 下面这张表是照各工具自己的 `Android.bp` 和
[`lzhiyong/android-sdk-tools`](https://github.com/lzhiyong/android-sdk-tools)
的 CMake 一个个查出来的，不是估的：

| 工具 | 源码在哪 | 上游那 18 个子模块里有吗 | 还要自己定义的库目标 |
|---|---|---|---|
| ~~`aidl`~~ | `system/tools/aidl`（自成一个仓库） | ❌ 另取一棵，21 MB | 无 |
| ~~`aapt`（v1）~~ | `frameworks/base/tools/aapt/` | ✅ 全有 | `libaapt`（22 个 `.cpp`，也在 base 里） |
| ~~`split-select`~~ | `frameworks/base/tools/split-select/` | ✅ 全有 | 复用上面那个 `libaapt` |
| ~~`dexdump`~~ | `platform/art` + `external/tinyxml2` | ❌ 另取**两**棵 | `libdexfile` `libartbase` `libartpalette` `libtinyxml2` |

**四个全做完了：**

| 工具 | 脚本 | strip 后 | 到哪一步了 |
|---|---|---|---|
| `aidl` | `tools/build-aidl.sh` | 2.3 MB | **aarch64 真机上编过了** |
| `aapt`（v1） | `tools/build-aapt.sh` | 1.9 MB | **aarch64 真机上编过了** |
| `split-select` | `tools/build-split-select.sh` | 1.0 MB | **aarch64 真机上编过了** |
| `dexdump` | `tools/build-dexdump.sh` | 1.0 MB | 配方在 x86_64 上验通，真机待验 |

加上 `aapt2` 和 `zipalign`，**`build-tools/` 那张 ELF 清单上除了两个废弃的
RenderScript 工具，全是自己编的了**。

先做 `aidl` 是因为它**唯一会真的卡住一个 app 构建**：工程里只要有 `.aidl`
（跨进程 service），没它就编不下去。另外几个更接近补齐清单。

四个脚本（含 zipalign）共用 [`tools/build-common.sh`](../../tools/build-common.sh) 的骨架，
加第五个工具照它开头的用法注释来，**别再复制一份**。

**每个都撞出一条只有跑过才知道的事**，记在这儿省得重踩：

- **判一个工具「能不能用」必须真执行一次，不能只看可执行位。** `tests/common.sh`
  里早就写着这条（`runs()`：`exit >= 126` 就是跑不了），我给 aapt2 写交叉验证时
  还是写成了 `[ -x ]`，**在真 ARM64 上当场翻车**：SDK 自带的 aapt2 文件在、有可执行位、
  但它是 x86_64 的，`exec` 得到 126，输出为空，被判成「两个实现对不上」。
  **这一条在 ARM64 上本来就做不成，而且那是应该的**——SDK 里没有能跑的官方 aapt2，
  这正是这个项目存在的理由。所以它现在降级成一句说明，只在 x86_64 对照机上真跑。
- **aapt2 的输出名带 ABI 后缀**（`bin/aapt2-arm64-v8a`），跟 cmake 目标名不一样。
  别的工具都是同名，所以 `tools/build-common.sh` 默认按目标名找产物——
  这一处要用 `BIN_NAME=` 覆盖。**这是把公共骨架抽出来之后才暴露的**：老的
  `build-aapt2.sh` 里本来有特判，抽的时候漏了。
- **aidl 要 flex 和 bison。** 它的词法/语法分析器是 `.ll` / `.yy`，Android.bp 的
  `srcs` 里直接列着——Soong 认得这两种扩展名、会自己去调，**CMake 不会**，得显式声明。
  而且用的是 bison 的 C++ GLR 骨架（`%skeleton "glr.cc"` + `%locations`），
  它除了 `.cpp/.h` 还会额外吐 `location.hh` 和 `position.hh`，生成的头会去 include
  它们，所以那个目录必须进 include 路径。**在源码里 grep 不到这两个文件名——
  它们是生成的，不是写出来的。**
- **aidl 的 `-Werror` 不是空谨慎。** 上游 `aidl_defaults` 带 `-Werror`，而
  `options.cpp:260` 有个 C++ 变长数组，clang 18 会报 `-Wvla-cxx-extension`。
  那条警告实测打出来了——照抄 `-Werror` 的话，这一处就直接编不过。
- **`aapt`（v1）硬性要求 `ANDROID_DATA`**，不设**直接 abort**，不是报错退出：
  `base/libs/androidfw/AssetManager.cpp:90` 是
  `LOG_ALWAYS_FATAL_IF(root == NULL, "ANDROID_DATA not set")`。AOSP 自己的构建
  环境里这个变量本来就有，把工具单独拿出来用就没有了。**aapt2 不吃这一条**
  （走的是 AssetManager2）——这是 v1 独有的坑。
- **照抄别人的 CMake，会连编不过的依赖一起抄来。** lzhiyong 那份给 aapt 链了
  `libprocessgroup`，照抄过来直接失败：`cgroup_map.cpp:222` 用了
  `ACgroupController_getMaxActivationDepth`，那个符号 **introduced in Android 36**，
  而我们按 `android-30` 编。回头查 `Android.bp` —— aapt 的依赖里本来就没有它，
  上游的 `cmake/aapt2.cmake` 也没链。**权威是 Android.bp，别人的 CMake 只能当参考。**
- **`split-select --generate` 的输出不是合法 JSON。** `"args": [en]` 里的 `en`
  没加引号。验它得按结构查字段，别拿 JSON 解析器 —— 这条是写测试时撞的：
  只有 base（输出 `[]`）时解析得动，一加真 split 就挂。
- **art 那批源码要一堆「源码里 grep 不到」的编译期常量**，Soong 通过
  `art_defaults` 给：`ART_FRAME_SIZE_LIMIT`、`ART_STACK_OVERFLOW_GAP_*`、
  `ART_BASE_ADDRESS`、`ART_PAGE_SIZE_AGNOSTIC`。权威出处是
  `art/build/art.go`（值）和 `build/soong/android/config.go`（base address）。
  **注意 `art.go` 里好几处给了两组值**——开了 sanitizer 是一组，普通构建是另一组，
  条件写得明明白白，别挑「看起来更保险」的那组。
- **dexdump 的一批 `operator<<` 是生成的**，跟 aidl 的 flex/bison 同类：
  `gensrcs` + `art/tools/generate_operator_out.py` 从头文件里的 enum 生成。
  不生成的话**编译全过、链接才炸**，而且信息很误导——
  `undefined symbol: art::operator<<(..., EncodedArrayValueIterator::ValueType)`，
  你在源码里 grep 这个函数体是找不到的，它本来就不存在。
- **`libartbase` 拖出第五棵源码树。** `base/metrics/metrics_common.cc` 直接用
  `tinyxml2::XMLElement`，而上游那 18 个子模块里没有 tinyxml2。
  又一次「先确认源码在哪棵树里」。

> **M3 的 `adb` 其实是 M1 验收的前置条件。** 里程碑按「能解锁多少」排序，
> 读起来像是可以依次做完；但 M1 的验收要求「样例工程编出**可安装的** APK」，
> 而在 ARM64 Linux 上你连装都装不上——SDK 自带的 `adb` 是 x86_64 的：
>
> ```
> $ adb devices
> bash: /opt/android-sdk/platform-tools/adb: cannot execute binary file: Exec format error
> ```
>
> 这是第 1.2 节那张 ELF 清单的现场版：**没有能跑的 adb，就没法跟设备说话，
> 也就没法完成 M1 的最终验收**。所以 `adb` 得从 M3 提到 M1 里来。
>
> 装了 Ubuntu 的 `adb`（`apt install adb`，原生 glibc arm64）之后还会再踩一次：
> SDK 通常会把 `platform-tools` 加进 `PATH`，而且排在 `/usr/bin` 前面，
> **于是那个跑不了的 x86_64 `adb` 一直盖着能用的那个**。新开一个 shell 就复发。
>
> ```bash
> # 把那个目录从 PATH 里摘掉
> export PATH=$(echo "$PATH" | tr ':' '
' | grep -v 'android-sdk/platform-tools' | paste -sd:)
> ```
>
> 治本是改 `.bashrc`。在 ARM64 上，**stock SDK 的 `platform-tools` 整个目录
> 都是跑不了的二进制**，留在 `PATH` 里只有害处。M4 做分发包时这一点要考虑：
> 装完之后用户的 `PATH` 应该指向能跑的那份。

### M3 · platform-tools

`adb`、`fastboot`、`etc1tool`、`hprof-conv`、`mke2fs`、`make_f2fs`、
`make_f2fs_casefold`、`sqlite3`。**八个，不是七个**——原来这里漏了
`make_f2fs_casefold`，是照 M4 的目标目录一个个数文件时才发现的。
第一节那张 `platform-tools` 清单里它一直在，这里没跟上。

**成本差得比 M2 还悬殊**，下面这张表照各工具的 `Android.bp` 和
[`lzhiyong/android-sdk-tools`](https://github.com/lzhiyong/android-sdk-tools)
的 `platform-tools/` 一个个查出来的：

| 工具 | 还要另取几棵树 | 源文件量 | 状态 |
|---|---|---|---|
| ~~`hprof-conv`~~ | 1（`platform/dalvik`，稀疏 556 KB） | **1 个**，一个库都不链 | 245 KB，**真机上编过了** |
| ~~`etc1tool`~~ | 1（`platform/development`，稀疏 2.4 MB） | 2 个（`libETC1` 在已有的 `native` 里） | 627 KB，**真机上编过了** |
| ~~`sqlite3`~~ | 1（`external/sqlite`，稀疏 23 MB） | 2 个（amalgamation） | 3.2 MB，**带 ICU**（2026-08-29 补上），见下 |
| ~~`make_f2fs`~~ | **1**（`external/f2fs-tools`，2 MB） | 33 | 651 KB，配方在 x86_64 上验通，真机待验 |
| ~~`make_f2fs_casefold`~~ | 0（跟 `make_f2fs` 同一棵树、同一份源码） | 同上 | 651 KB。只多两个 `-D`，目标定义并在 `cmake/make_f2fs.cmake` 里。**真机上五步全绿**，含跟官方产物的逐字节比对 |
| ~~`mke2fs`~~ | 1（`external/e2fsprogs`，43 MB） | 156 | 972 KB，配方在 x86_64 上验通，真机待验 |
| ~~`fastboot`~~ | **3**（`system/extras` `external/avb` `system/tools/mkbootimg`，都很小） | 26 | 1.5 MB，**验收有边界，见下** |
| ~~`adb`~~ | **5**（`libusb` `mdnsresponder` `openscreen` `brotli` `zstd`） | 14 个 client 源文件 + 30 个 `static_libs` | **编出来了** —— strip 后 5.8 MB（官方 7.9 MB），真机上 `--verify` 五步全绿。含一个 Java 子构建，见下 |

**做完的这三个，验收里都有跟官方 x86_64 产物逐字节比对的部分**（第五节第 6 条），
全部对上：`hprof-conv` 比转换后的字节串，`etc1tool` 比 `.pkm` 的 sha256，
`sqlite3` 比版本行和**建库文件的 sha256**——最后那条顺带证明了那二十几个 `-D`
一个都没抄错（页布局受它们影响，错一个哈希立刻不一样）。

> ✅ **`sqlite3` 的 ICU：2026-08-29 补上了，跟官方对齐。**
>
> 这段以前是「已知缺口：没有 ICU」。现在 `cmake/icu.cmake` 从 `external/icu`
> （稀疏取 `icu4c/source/{common,i18n,stubdata}`，66 MB）编出
> `libicuuc`（201 个 .o）/ `libicui18n`（254 个）/ `libicuuc_stubdata`（1 个），
> `sqlite3` 开 `-DSQLITE_ENABLE_ICU` 链上去——**跟 `Android.bp` 里 host 变体一样**。
>
> 拿当初记下的官方 platform-tools r35.0.2（x86_64）实测值逐条对：
>
> | | 官方 | 我们（补 ICU 前） | 我们（现在） |
> |---|---|---|---|
> | `SELECT icu_load_collation('en_US','en')` | `ICU error: ucol_open(): U_FILE_ACCESS_ERROR` | `no such function` | **同官方，逐字一致** |
> | `SELECT upper('äöü')` | `ÄÖÜ` | `äöü`（原样） | **`ÄÖÜ`** |
>
> **「照官方」也包括「官方同样没带 ICU 数据」这一半。** `ucol_open()` 报
> `U_FILE_ACCESS_ERROR` 不是我们缺东西，是 stubdata 的正常表现。这不是推的，
> 是拆官方二进制查的（qemu 已卸，不用跑它）：`llvm-readelf -d` 看 `NEEDED` 里
> **没有** `libicuuc.so`（ICU 是静态链的）；整个 `platform-tools` 里没有任何
> `*.dat`；官方那个二进制才 3.6 MB，而真数据光 `icudt##l.dat` 就 28 MB；
> `strings` 里有 `icudt78_dat` 和 `U_FILE_ACCESS_ERROR`。
>
> 顺带查出来一处真差别：**官方是 ICU 78，我们这棵树（`platform-tools-35.0.2`
> tag）是 ICU 75**。数据文件名跟版本绑死，将来要挂真数据别拿错版本。
>
> **`upper()` 不靠数据也对，为什么**：大小写属性是编译进 `libicuuc` 的
> （`common/ucase_props_data.h`，67 KB），排序规则才在 `.dat` 里。所以
> 「stubdata 下 `upper()` 正常、`ucol_open()` 失败」不矛盾——我一开始以为
> 「没数据 = 什么都不灵」，错了。
>
> 编这两个大库路上有两个坑，都记在 `cmake/icu.cmake` 里：NDK sysroot 那份
> `uconfig_local.h` 会把 ICU 的 C++ API 关掉（那份是给**用**系统 ICU 的 app 的），
> 和 NDK 总会加的裸 `-DANDROID` 宏——在 ICU 源码里它的含义是「**本次构建由
> Soong 驱动**」，不是「目标是 Android」。
>
> `tools/build-sqlite3.sh` 的 4/4 从「断言缺口还在」翻成了**正向断言**：两条探针
> 跟官方不一样就红，**包括「有人挂了真数据」这种好事**——好事也得先改文档。
> 那两条的红是实测过的（拿补 ICU 前那份旧二进制跑，退出码 1）。
>
> （**一个一开始搞错、被自己的测试逮住的点**：`REGEXP` 不是 ICU 提供的，
> sqlite 的 `shell.c` 自带 regexp 实现，两边都有，别拿它当判据。）

> **顺带把这 13 个工具按用途分一下**，判缺口的轻重时用得上：
>
> | 用途 | 工具 | 缺了会怎样 |
> |---|---|---|
> | 打包 | `aapt2`、`zipalign`（+ NDK 工具链，有 native 代码时） | **APK 出不来**——M1 的验收就卡在这 |
> | 装机 | `adb`、`fastboot` | APK 装不到设备上 |
> | 刷机／镜像 | `make_f2fs`、`make_f2fs_casefold`、`mke2fs` | 做不了 system/userdata 镜像 |
> | 调试／老工具 | `sqlite3`、`hprof-conv`、`dexdump`、`aapt`、`aidl`、`etc1tool`、`split-select` | 对应的调试手段没有 |
>
> ⚠️ **这张表分的是「缺了影响谁」，不是「要不要」。** 这个项目的目标是
> **补上 Google 不发的那套 ARM64 SDK/NDK**——对标的是官方 x86_64 包的完整度，
> 不是「够打包就行」。打包那行是最核心的用例、也是 M1 的验收标准，
> 但**其余三行同样在范围内**，一个都不砍。
>
> 拿这张表判缺口的轻重（比如「某个功能差异该多着急」），别拿它判去留。

`mke2fs` 顺带产出七个 `libext2_*` 静态库加 `libsparse`，`make_f2fs` 直接用了其中的
`libext2_uuid` 和 `libsparse`——所以它**只差 `f2fs-tools` 一棵树**。
（上面这张表原来估的是「三棵，含 `lz4`」。实际查 `Android.bp`：`lz4` 是
`sload_f2fs` 用的，`make_f2fs` 根本不需要。**估算和实查又一次不一样**，
所以流程的第一步永远是先查 `Android.bp`。）

**`mke2fs` 跑起来要一份 `mke2fs.conf`**（`MKE2FS_CONFIG` 指过去或装到
`/etc/mke2fs.conf`），没有会直接 abort。官方的 platform-tools 里带着一份——
**M4 做分发包时别漏了这个文件**，它不是二进制但缺了就用不了。

> ⚠️ **`fastboot` 编出来了，但它的验收跟别的工具不是一个性质。**
>
> 前面那些工具都能在本机干完整的活（打 APK、造文件系统、读 dex），`fastboot`
> 的活是**跟一台处在 fastboot 模式的设备说话**。没有设备，`--verify` 只能验到
> 「跑得起来、参数认得出、USB 扫描不炸」三条——**这不等于它能用**。
>
> 真正的验收得把设备重启到 bootloader，然后 `fastboot devices` 看得到它、
> `fastboot getvar product` 拿得到型号。跟 `tests/hello-*` 需要真手机是同一类限制，
> 脚本跑完会把这段话打出来，别把那三条当成通过了。
>
> 另外三个坑：
> - **`fastboot` 第一版在别人的干净机器上第一步就死**：`cmake/fastboot.cmake` 引用
>   `external/lz4`，而**没有任何脚本取这棵树**——我这边有，是因为探路时手动
>   `git clone` 过一次。**在自己机器上永远发现不了。** 现在
>   `tools/check-fetch-coverage.sh` 专门查这件事：每个 `cmake/<工具>.cmake` 引用的
>   源码树，是不是都有脚本负责取。不联网不编译，随时能跑。
> - **`fastboot <不认识的子命令>` 会挂住等设备**（官方那个也一样，实测跑满两分钟
>   没退）。写测试时红自检要用**参数**解析的错误路径，不能用子命令。
> - **版本号后缀必然不同**：`fastboot --version` 打的是
>   `<PLATFORM_TOOLS_VERSION>-<build_number>`，官方是 `35.0.2-12147458`，
>   我们是 `35.0.2-`（空）。那个数字是 AOSP CI 的构建号，**我们没有也不该编一个**
>   ——编上去等于冒充某一次官方构建。属于第五节第 6 条那张表里「运行环境」一类。

> **`adb` 的实查结果（2026-08-28 重查了一遍，跟第一版有出入）。**
>
> `packages/modules/adb/Android.bp` 里 `adb_binary_host_defaults` 的
> `static_libs` 列了 30 项（`liblog` 重复一次，实际 29）。逐个查定义位置之后
> 分成五类——**第一版把它算重了，因为漏了「上游那套 cmake 本来就在编」这一类**：
>
> | 类 | 个数 | 是什么 |
> |---|---|---|
> | 已经有 cmake 目标 | 8 | `libandroidfw` `libbase` `libcutils` `libdiagnose_usb` `liblog` `liblz4` `libutils` `libziparchive`（`libz` 用系统的） |
> | **上游 cmake 已经在编** | 3 | 顶层 `CMakeLists.txt` 就 `add_subdirectory(submodules/boringssl)` 和 `(submodules/protobuf)`：`libcrypto`→`crypto`、`libssl`→`ssl`、`libprotobuf-cpp-full`→`libprotobuf` |
> | 第三方树自带 CMake | 2 | `libbrotli`（顶层 `CMakeLists.txt`）、`libzstd`（`build/cmake/`） |
> | 第三方，要自己照 `Android.bp` 写 | 6 | `libusb` `libmdnssd` `libcrypto_utils`（在 `core/libcrypto_utils`）、`libopenscreen-discovery`（32 个源文件）、`libopenscreen-platform-impl`（3 个）、`libopenscreen_absl`（22 个） |
> | adb 仓库自己的 | 10 | `libadb_host` `libadb_crypto` `libadb_protos` `libadb_host_protos` `libapp_processes_protos_full` `libadb_pairing_auth` `libadb_pairing_connection` `libadb_sysdeps` `libadb_tls_connection` `libfastdeploy_host` |
>
> **第一版标着「还没找到出处」的两个都查到了**：`libcrypto_utils` 在
> `system/core/libcrypto_utils`，`libapp_processes_protos_full` 就在
> **adb 树自己的 `proto/Android.bp`** 里。
>
> **`libopenscreen_absl` 不需要第六棵树。** 第一版把它跟 `libusb` 那几个并列成
> 「另外五棵树」，其实 abseil 的源码就在 `openscreen/third_party/abseil/src/`，
> 而且只用到 22 个 `.cc`。
>
> **代码生成有三处**（前面的工具最多一处）：
>
> | | 干什么 | 难点 |
> |---|---|---|
> | protoc → C++ | `adb/proto/*.proto`、`fastdeploy/proto/ApkEntry.proto` | 跟 aapt2 那套一样，好办 |
> | `bin2c_fastdeployagentscript` | 把 `deployagent.sh` 转成 C 数组 | 一条 `xxd -i`，好办 |
> | `bin2c_fastdeployagent` | 把 **fastdeploy agent** 转成 C 数组 | **输入是一个 Java 产物**，见下 |
>
> **那个 Java 子构建具体是什么**（查到 `deployagent.sh` 才看清）：
>
> ```sh
> #!/system/bin/sh
> base=/data/local/tmp
> export CLASSPATH=$base/deployagent.jar
> exec app_process $base com.android.fastdeploy.DeployAgent "$@"
> ```
>
> 也就是说 `kDeployAgent` 那个字节数组是一个 **dex 过的 jar**。要造它得：
> `protoc --java_out` 编 `fastdeploy/proto/ApkEntry.proto`（lite）→ `javac`
> 那 4 个 `.java` 加生成的 proto 类 → `d8` 打成 dex → 打包成 jar。
> **javac、d8、protoc 我们都有**，d8 还是官方那个跟架构无关的 jar。
> 缺的是 protobuf 的 Java lite 运行时——`submodules/protobuf/java/` 里有源码。
>
> `lzhiyong` 那份是把生成好的 `deployagent.inc` 当补丁带着的——**那是别人的产物，
> 第五节不许直接用**。要做就自己编。
>
> **它也是唯一一个「不做也不太卡」的**：Debian/Ubuntu 有 arm64 的 `adb` 包（第三节），
> M1 的验收用的就是发行版那个。只有做正式分发包（M4）时才必须换成自己编的。

### M4 · 做成能装的东西

产出可解压到 `$ANDROID_HOME` 的分发包，目录结构与 `sdkmanager` 装出来的一致。
加分项：一个能被 `sdkmanager` 识别的本地 repository XML，让它成为一个可添加的 SDK 源。

```bash
tools/make-dist.sh --check   # 只报缺什么，不写文件
tools/make-dist.sh           # 摆好目录、写 PROVENANCE.txt、打 tar.gz
```

**目录清单不是写死的，是运行时从官方装出来的那份读的。** 挨个文件分类：

| 分到哪 | 判据 | 怎么处理 |
|---|---|---|
| 自己编的 | `$WORK/out/` 里有同名产物 | 用我们的 |
| 目标产物 | 路径里带 ABI 目录名（`arm64-v8a` / `x86_64` …） | **原样拷，哪怕是 x86 的** |
| 跟架构无关 | 不是 ELF | 原样拷 |
| 缺口 | host 位置上的 ELF，而我们没有 | **丢掉并报出来** |

第二行是这次做的时候撞出来的，值得单记：

> **一个 x86_64 的 `.so` 未必是「跑不了的砖」。**
> `build-tools/<rev>/renderscript/lib/` 底下按 ABI 分了四个目录，
> 里面的 x86 二进制是**给 x86 设备用的目标产物**，是要打进 APK 的。
> 按架构一刀切会把它们全删掉。判据得是**位置**：这个文件是给谁跑的。
> 官方 `build-tools` 里 39 个 ELF，只有 9 个是 host 二进制。

反过来，host 位置上的 x86 二进制**一个都不放进去**——README 上面记过，
`PATH` 里放一堆跑不了的二进制只有害处。这也是这个包唯一的硬指标：
打完包逐个文件 `file` 一遍，host 位置上的 ELF 必须全是 `ARM aarch64`，
有一个不是就拒绝出包（往 `$WORK/out/` 里塞一个 x86 的产物试过，会红）。

**版本号不冒充，也不自己编一个。两个包的答案还不一样**，因为「这个包里的东西
主要是谁的」不一样：

| 包 | `Pkg.Revision` 用谁的 | 为什么 |
|---|---|---|
| `build-tools/<rev>/` | **借出 jar 的那个官方包**的版本 | `d8.jar` / `apksigner.jar` 确实就是那一版，我们也不重编它们，AGP 按目录名判能力判的也是它们 |
| `platform-tools/` | **我们源码 tag** 的版本 | 这个包里除了 `mke2fs.conf` 和 `NOTICE.txt`，几乎全是我们编的 |

第二行是真机上撞出来的：那台机器官方装的 `platform-tools` 是 **37.0.1**，
而我们的 ELF 编自 `platform-tools-35.0.2`。照搬就会打出一个标着「37.0.1」、
里面装着 35.0.2 二进制的包——**那是在说一件不成立的事**。
（容器里那份官方正好是 35.0.2，两者相等，这个坑在本地怎么跑都照不出来。
又一次。）

同时：

- `Pkg.UserSrc` 改成 `true`，加一行 `Pkg.Desc` 说明是谁重建的、源码哪个 AOSP tag；
- 包里带一份 `PROVENANCE.txt`，**逐个文件**写清楚哪些是自己编的、哪些是从官方
  包原样拿的、哪些没放进来。**「哪些不是我们编的」必须跟着包走，不能只写在
  README 里。**

**「缺」要分成两类报，混在一起就是在说假话。** 第一版只有一个「丢掉 N 个，
我们还没有对应的」——对 RenderScript 那几个来说，「还没编出来」是假的，
我们根本**不打算**做。分开之后：

| | 自己编的 | 目标产物原样拷 | 跟架构无关原样拷 | **真缺口** | 不打算做 |
|---|---|---|---|---|---|
| `build-tools/<rev>/` | 6 + `lld-bin/lld` | 24 | 130 | **0** | 8 |
| `platform-tools/` | 8（含 `adb`） | 0 | 4 | **0** | 1 |

「不打算做」那 9 个全是 RenderScript 及其连带：`bcc_compat`、`llvm-rs-cc`、
`lib64/lib{LLVM_android,bcc,bcinfo,clang_android}.so`，加上两个
`lib64/libc++.so*`——**只有上面那几个动态链它**，我们自己的产物一律
`c++_static`。Google 从 Android 12 起废弃了 RenderScript。

所以整个分发包**一个真缺口都没有了**（2026-08-28，`adb` 编出来之后在那台
aarch64 机器上实测）。剩下的九个全在「不打算做」那一栏。

`lld-bin/lld` 是 `tools/build-llvm.sh` 顺带编出来的（`LLVM_ENABLE_PROJECTS`
里有 `lld`），`make-dist.sh` 去 `$WORK/out/llvm/linux-aarch64/bin/lld` 找，
在就用——M1 的产物就是这么接上 M4 的。

那张「不打算做」的名单**自己也有一条自检**：每一项都必须真的是官方包里的文件，
否则当场判失败（塞了个 `not-a-real-file` 试过，会红）。理由同
`tools/build-llvm.sh` 第 5 步那张放行名单——**放行名单比检查清单危险，
它的错误方向是静默的**。

#### 出包前的四条硬指标

| 验什么 | 怎么判 |
|---|---|
| host 位置上的 ELF 全是 `ARM aarch64` | 逐个 `file`；ABI 目录下的目标产物放过 |
| **它们真的能跑** | 逐个执行，退出码 < 126（`tests/common.sh` 的 `runs()` 那条判据），`timeout` 的 124 单独算失败 |
| `mke2fs.conf` 在 | 缺了 `mke2fs` 直接 abort，而它不是二进制，最容易漏 |
| 两个 `NOTICE.txt` 都在且非空 | 许可证声明必须跟着包走 |

第二条是补上去的——第一版只问了 `file`「这是什么架构」，而**那正是 `aapt2`
那次栽的地方**：文件在、有可执行位、`exec` 是 126。第五节第 2 条说的就是这个。
非 aarch64 机器上这一条会跳过并明说「**没验过**」，不当通过。

#### 真 ARM64 机器上的产出

```
build-tools/36.0.0   自己编的 7 个（含 lld-bin/lld）+ 目标产物 24 + 架构无关 130
                     真缺口 0，不打算做 8
platform-tools       自己编的 7 个 + 架构无关 4
                     真缺口 1（adb），不打算做 1
四条硬指标           全绿，其中 14 个 host 二进制逐个真跑过
产物                 android-sdk-linux-arm64-36.0.0.tar.gz，55 MB
```

**装法**：`tar -C $ANDROID_HOME -xzf android-sdk-linux-arm64-36.0.0.tar.gz`

#### 加分项：`tools/make-repo.sh`（sdkmanager 能识别的本地仓库）

把 `make-dist.sh` 摆好的树做成每包一个 zip + 一份 `repository2-3.xml`。
格式不猜，拿 Google 自己那份
（`dl.google.com/android/repository/repository2-3.xml`，412 KB）当权威。
从它身上量出来三件事：

**一、schema 支持 `linux/aarch64`，但 Google 一个都没发。** 把那份文件里所有
`<archive>` 的 `host-os`/`host-arch` 组合数一遍：

| os | arch | 个数 |
|---|---|---|
| linux | （无） | 174 |
| windows | （无） | 174 |
| macosx | （无） | 171 |
| macosx / linux / windows | x64 | 各 61 |
| **macosx** | **aarch64** | **58** ← arch 字段是有的 |
| windows | x86 | 18 |
| **linux** | **aarch64** | **0** |

也就是说**这个项目的前提在分发元数据这一层也成立**：不是格式表达不了，
是没人发。我们这份 XML 填的就是那个空格。

**二、zip 内部的顶层目录名**，下了官方包看的：`platform-tools_r37.0.1-linux.zip`
里是 `platform-tools/`，`build-tools_r36_linux.zip` 里是 `android-16/`。
sdkmanager 装的时候会把顶层目录整个改名成安装路径。

**三、`remotePackage` 里字段是 `sequence`**，顺序错了就不合法。

**验到哪一步，说清楚：**

- **验了**：产出的 XML 用**官方 XSD** 校验通过。那四个 xsd
  （`sdk-repository-03` / `sdk-common-03` / `repo-common-02` / `generic-02`）
  是从 cmdline-tools 的 jar 里取出来的。**校验器先在 Google 自己那份
  `repository2-3.xml` 上校准过**——它必须通过，否则说明是校验器搭错了。
  还做了变异测试：把 `display-name` 挪到 `revision` 前面，当场红。
- **没验**：sdkmanager / Android Studio 真的去装它。试过两条路都不通——
  新版 cmdline-tools（rev 23）的 `sdkmanager` 只是个壳，转发给新的 `android`
  CLI，**不认 `SDK_TEST_BASE_URL`**（起了本地 http 服务，一次请求都没收到）；
  旧版（rev 13）还有老的 `sdkmanager`，同样没请求本地服务。
  **所以这一条是「格式合法」，不是「装得上」。**

**这版不做**：`platforms/android-XX`（纯 Java + 数据，用户手上那份直接能用）。

#### 加分项：`tools/make-ndk-dist.sh`（NDK 也打成包）

`make-dist.sh` 出的包解压完，**纯 Java 的 app 立刻能编**——aapt2 + d8 +
apksigner + zipalign + android.jar，一条都不碰 NDK。但要编带原生库的 app，
用户还得自己走一遍：装官方 NDK → `patch-ndk.sh` → `build-llvm.sh`（一小时）
→ `build-python.sh`。**那是这个包此前最大的门槛**，这个脚本把它抹平。

```bash
tools/make-ndk-dist.sh [NDK 路径]
```

**判据跟 `make-dist.sh` 一样：按位置，不按架构。但 NDK 的位置判据跟 SDK
不是同一条**——这里栽过一次，值得写下来：

| | 目标产物在哪 | 目录名长什么样 |
|---|---|---|
| SDK | `renderscript/lib/<abi>/` | ABI：`arm64-v8a`、`x86_64` |
| NDK | `sysroot/usr/lib/<triple>/` | **三元组**：`x86_64-linux-android`、`arm-linux-androideabi` |

把 `make-dist.sh` 的 `is_abi_path()` 直接搬过来，`sysroot/` 底下 1000 多个
x86/ARM 目标库会被当成「host 位置上的异架构文件」，包根本打不出来。所以
NDK 这边反过来写：**列出 host 二进制会出现的位置**，其余一律目标产物。数出来
只有七处（`bin/`、`libexec/`、`python3/`、`lib/` 那一层、`prebuilt/<tag>/`、
`shader-tools/<tag>/`、`simpleperf/bin/linux/<arch>/`）。

**这条名单在官方原版 x86_64 NDK 上校准过**——先拿一份已知答案的树跑，
数出来的必须对得上：

```
host 位置 ELF          133 个，133 个全是 x86-64   ← 一个目标产物都没被误判进来
目标位置 ELF          1753 个
有 Linux INTERP 却不在 host 位置的：0 个            ← 一个 host 二进制都没漏在外面
符号链接 35 个，绝对路径 0、断链 0
```

**「放行名单比检查清单危险」，所以这条名单自己也要被查。** 八道检查，每道
判据不同，前面还有一道必须失败的自检：

| | 查什么 | 判据 |
|---|---|---|
| 自检 | 把坏文件塞进假树 | 造 4 个 64 字节的合成 ELF 头（`file(1)` 就够报架构，不用真二进制），host 位置那个必须被抓、目标位置那俩必须放行；再从本机拷一个动态链接的 host 二进制藏进 `sources/`，验二必须逮住它 |
| 验一 | host 位置上的 ELF | 全是 aarch64；**且数量 ≥ 40**（名单写错路径就会一个都匹配不上，「无事通过」） |
| 验二 | 整棵树 | 凡是要 `/lib*/ld-linux-*` 的都是 host 二进制，**不看位置**——它就不该出现在验一放行掉的地方。这条是验一那份名单的兜底 |
| 验三 | host 位置的 `.a` | `file(1)` 对静态库只说「ar archive」，不说架构——把成员掏出来问。没有 `ar(1)` 就**明说没查**，不算通过 |
| 验四 | 符号链接 | 不许断链、不许指到包外（薄壳工具链就是拿软链搭的） |
| 验五 | 被丢掉的路径 | 丢完东西之后，包里不许有**可执行**文件还指着它。文档提一句路径是说明不是引用，不算 |
| 验六 | `bin/` 里的二进制 | **真跑一遍**，退出码 < 126。只跑 `bin/`——`lib/` 里的 `.so` 也带 `+x`，跑起来必 segfault（139 > 126），拿它们当「跑不起来」是误报 |
| 验七 | 顶层入口脚本 | `ndk-stack` / `ndk-gdb` / `ndk-which` / `ndk-lldb` 是 shell 脚本，验六扫不到。同样真跑，**127 单独点名**——那是「转发过去的目标不在」 |
| 验八 | 整个包 | `ANDROID_NDK_HOME` 指到包里，`ndk-build` 真编出一个 `arm64-v8a` 的 `.so`，且它**不带** Linux INTERP（否则说明 target 默认值不对） |

四个 host 目录的处置：

| 目录 | 处置 | 理由 |
|---|---|---|
| `toolchains/llvm/prebuilt/<tag>/` | 换成自己编的 `linux-aarch64`，另加一个 `linux-x86_64 -> linux-aarch64` 的软链 | `build-llvm.sh` 的产物；软链是给**第三方工具**用的——见下 |
| `prebuilt/<tag>/` | **拆开** | 这个目录是**混的**——见下 |
| `shader-tools/<tag>/` | 丢 | glslc / spirv-\*，没有 aarch64 版，编 Vulkan shader 才用得上 |
| `simpleperf/bin/linux/<arch>/` | 丢 | 官方只有 x86_64 那一份。`bin/android/<abi>/` 是**跑在设备上的**，跟 `renderscript/lib/<abi>/` 同一类，照搬才对 |

**`prebuilt/` 曾经被整个丢掉，那是个 bug，第一次真机出包才发现。** 它的
`bin/` 里九个文件是混的：

| 文件 | 类型 | 处置 |
|---|---|---|
| `make` `yasm` `vsyasm` `ytasm` | x86-64 ELF | 丢（连同 yasm 的 `include/` `lib/` `share/`） |
| `ndk-stack` `ndk-which` `ndkstack.pyz` | 脚本 / zipapp | **搬进 `prebuilt/linux-aarch64/bin/`** |
| `ndk-gdb` `ndkgdb.pyz` | 脚本 / zipapp | **不带**——见下 |

`ndk-stack` 和 `ndk-gdb` 看着一样，其实差别是决定性的，值得记：

```python
# ndkstack.pyz —— 从自己所在目录推导，搬过去就自动对
ndk_host_tag = ndk_bin.parent.name
path = ndk_root / "toolchains/llvm/prebuilt" / ndk_host_tag / "bin" / "llvm-symbolizer"

# ndkgdb.pyz —— 写死
def get_llvm_host_name() -> str:
    ...
    return "linux-x86_64"
```

而且 `ndk-gdb` 要 `liblldb.so`，**我们没编 lldb**。带进去就是「文件在、一跑就
错」，比没有更糟。所以：`ndk-gdb` / `ndkgdb.pyz` 不进包，顶层的 `ndk-gdb` /
`ndk-lldb` 换成**说明桩**——一跑就把原因写在脸上，退出码 1，而不是留一个转发到
不存在的东西、报 `127 not found` 的脚本。

判据**不写死**：看 `toolchains/llvm/prebuilt/linux-aarch64/bin/lldb` 在不在。
将来编了 lldb，`ndk-gdb` 会自动带上、桩自动消失（两条分支都测过）。而 NDK 顶层的 `ndk-stack` /
`ndk-gdb` / `ndk-which` / `ndk-lldb` 都**写死**转发到
`prebuilt/linux-x86_64/bin/`（`patches/ndk/` 没管这几个文件——对装了官方 NDK
的用户来说它们本来就能用，是我们的包丢掉了那份才需要改，所以这是打包脚本的
活）。实测原版 r27b：

```
prebuilt 在  ->  ./ndk-stack --help 退出码 0
prebuilt 丢  ->  退出码 127，not found
```

所以现在：非 ELF 的搬到 `linux-aarch64/`，顶层入口的转发路径跟着改，
**再加一道验五**专门查「丢完东西之后谁还指着它」——头一轮六道检查一道都没
抓到这个，因为它们只看 ELF 和符号链接。

**包必须自足，所以打包时还会删两类东西**，逐个报出来：

- **指向包外的软链**。真遇到过：打包机上有人为了凑合建了
  `prebuilt/linux-aarch64/bin/make -> /usr/bin/make`。它在那台机器上好好的，
  进了包就是「依赖宿主机的绝对路径」——换台机器要么断链，要么歪打正着地生效。
  删它是安全的，依据是 `build/ndk-build` 自己的逻辑：
  ```sh
  GNUMAKE=$ANDROID_NDK_ROOT/prebuilt/$HOST_TAG/bin/make
  [ ! -f "$GNUMAKE" ] && GNUMAKE=$(which make)
  ```
  `-f` 跟随软链，所以「断链」和「文件不在」走的本来就是同一条路。
  （`init.mk` 里那个 `HOST_MAKE` 全仓库没有一处读它，是个死变量，别被它误导。）
- **`patch(1)` 的残留** `*.orig` / `*.rej`。`.orig` 是**没打补丁的原版**，
  留在分发包里既没用又误导人。

删完之后验四再查一遍——它现在是这段删除逻辑的**兜底**：还报就说明没删干净。
（变异测试：把 `rm` 换成 no-op，验四当场红。）

**为什么还要留一个叫 `linux-x86_64` 的软链。** `patches/ndk/` 的 0002/0003/0004
已经把 NDK 里四处写死的 host tag 改成按架构判断（两个 cmake toolchain 文件、
`make_standalone_toolchain.py`、`init.mk`）。但**第三方工具不读我们的补丁**——
它们照着 Google 那份写死的路径直接拼。真遇到过一个项目这么查：

```bash
compgen -G "$ANDROID_HOME/ndk/*/toolchains/llvm/prebuilt/linux-x86_64/bin/clang"
```

补丁修好的是「NDK 自己怎么算」，管不着「别人怎么猜」。一个符号链接让两条路
都通，成本为零。

打包前先查三条前提，缺哪条报哪条：工具链是自己编的（不是薄壳、`sysroot` 和
`lib/clang` 是真目录不是软链）、里头的 `python3` **自足**（判据是
`sys.prefix` 落在工具链内，不是「文件在不在」）、NDK 的补丁打全了。

**验到哪一步，说清楚：**

- **验了**（在 x86_64 容器里）：名单在官方原版 NDK 上的校准数（133 / 1753 / 0 / 35-0-0）；
  自检的四条；各道检查的**变异测试**——host 位置塞 x86 ELF、塞 x86 `.a`、
  绝对软链指到包外、`source.properties` 少了 `Pkg.Desc`、留一个可执行文件指着
  被丢的目录，全都当场红；「`.a` 里全是非 ELF 成员」时报**「没判」**而不是
  「都对」；验五在**文档**提到被丢路径时不误报，同样内容加上可执行位就报。
  整条流水线在一棵合成的假 NDK 上跑通。
- **验了**（在真 ARM64 机器上）：包 563 MB，八道全过——验一 107 个 host ELF、
  验二 32 个、验四 23 个软链、验五 4 个丢掉的目录没人再指着、验六 32 个二进制
  真跑过、验七 4 个顶层入口真跑过、验八 `ndk-build` 真编出 `libx.so`。
- **验了**（端到端，这条才是验收）：把 **tar.gz 解压到一个全新位置**
  （`mktemp -d`，不是打包时那棵树），`ANDROID_NDK_HOME` 指过去跑
  `tests/hello-native/build.sh` ——`ndk-build` → `javac` → `d8` → `aapt2` →
  `zipalign` → `apksigner` 一路下来出 APK，装到真机跑出 `20 + 22 = 42`。
  中间隔着 tar 的打包/解包（权限位、软链、空目录都可能丢），所以它验的不只是
  编译器。**而且这一遍没传 `NDK_HOST_PYTHON`**：`ndk-build` 一声没吭地跑完，
  说明它用的是包里自带那份 python3——「自足」是这么证出来的，不是声明的
  （真找不到不会静默降级，`patches/ndk/0005` 让它直接 `$(error)`）。
- **没验**：验三在我们的包上是 **0 个静态库**——`lib/` 那一层没有 `.a`，
  所以这条**没判过任何东西**，别当它是「查过了都对」。

**这一节的三个 bug 全是出包之后才发现的**，值得记一笔：`prebuilt/` 整个丢掉
（第一次真机出包，是「丢掉 prebuilt/linux-x86_64(7.4M)」这行输出让人起疑，
不是哪道检查报的）、`make` 软链指向 `/usr/bin/make`（验四抓的）、
搬过去的 `ndk-which` 里还写着旧路径（验五抓的）。八道检查里有三道
（验四、验五、验七）是被这几次教出来的——**在合成的假树上八道全绿，
在真机上照样能红。**

#### 加分项：`tools/test-clean-machine.sh`（干净机器验收）

**到这里为止所有验证都在打包那台机器上做的**，而那台为了编 LLVM 和 CPython
装了 `zlib1g-dev`、`libffi-dev`、`libncurses-dev`、`libbz2-dev`、系统 clang、
cmake、ninja……包在那台上跑得通，说明不了它在别人机器上跑得通。

这是第五节第 1 条换了个轴：那条说「x86 上编过了不算数」，这条说
**「编包那台上能用不算数」**。

```bash
tools/test-clean-machine.sh            # 两个阶段
tools/test-clean-machine.sh --deps     # 只量依赖（不用 docker，x86_64 上也能跑）
tools/test-clean-machine.sh --docker   # 只跑容器实测
```

**一、量依赖。** 判据很省事：`DT_NEEDED` 里有 `libc.so.6` 的就是 Linux host
二进制——Android 目标产物连的是 `libc.so`（不带 `.6`）和 `liblog.so` 那套，
天然分得开，不用再猜位置。然后两件事：

- 除了 glibc 那套和包自带的，还连着哪些系统库，各是谁要的；
- **最高的 `GLIBC_x.y` 符号版本**——这条决定包能装在哪些发行版上。低于它的
  系统上是**开都开不起来**，报 `version GLIBC_x.y not found`，跟「缺个库」
  不是一回事。

  作个参照：官方 x86_64 NDK 的 clang 只要 `GLIBC_2.16`，Google 拿老 sysroot
  编的。我们直接在打包机上编，门槛就是打包机的 glibc。**这不是 bug，是取舍**
  ——换来的是不用维护一套 sysroot。但它决定这个包发给谁能用，所以得量出来
  写在明处，别让人装上了才发现。

**二、裸容器实测。2026-08-29 第一次真跑了**（这台机器原来没装 docker）：

| 镜像 | 第一次跑（2026-08-29 上午） | 修完之后 |
|---|---|---|
| `ubuntu:24.04` | 一路到 T3 | ✅ T3 |
| `ubuntu:22.04` | **T1 就红**：``version `GLIBC_2.36' not found`` | ✅ **T3** |
| `debian:12` | **T1 就红**：缺 `GLIBC_2.38` | ✅ **T3** |

右边那栏是**两轮修完之后**的：一是把 host 工具改到 `ubuntu:22.04` 容器里编
（门槛 `2.38 → 2.34`，见第三节第 2 条），二是下面第 3 条那个编码 bug。

> **跑这一遍抓出了两个我们自己的毛病，都是「测试本身不对」那一类：**
>
> 1. **T1 的判据是错的。** 原来写 `rc < 126` 就算跑起来了 —— 那对静态二进制
>    成立，对动态链接的不成立：`ld.so` 拦下来时退的是 **1**。于是 22.04 和
>    debian:12 上明明起不来的 clang 被判成 `T1=ok`，连结论表都印着 ok。
>    改成看它有没有真打出 `clang version`。
>    **跟 aapt2「exec 是 126」那条是同一枚硬币的两面：126 抓得住一类，
>    抓不住另一类；判据得是「跑起来了」的直接痕迹。**
> 2. **L2 的装包清单漏了 `file(1)`。** 24.04 上一路绿到 T3，然后挂在
>    `file: command not found` —— 挂的不是产品，是我们自己的测试缺依赖，
>    但报出来长得像产品坏了。补进清单，也补进 INSTALL 的依赖表。
> 3. **`tests/hello-*/build.sh` 的 `javac` 没带 `-encoding UTF-8`。**
>    门槛降到 2.34 之后 22.04 和 debian:12 能起 clang、能 ndk-build 了，却仍然
>    挂在 T3，报 120 个 `unmappable character (0xE7) for encoding US-ASCII` ——
>    **源码里的中文注释**。javac 不带这个参数时用**平台默认编码**，而
>    **JDK 18 起才默认 UTF-8**（JEP 400）：24.04 是 JDK 21 所以一直没露馅，
>    22.04（JDK 11）和 debian:12（JDK 17）在 C locale 下默认 US-ASCII。
>    **我一开始以为是 JDK 版本太老读不了 API 36 的 android.jar —— 猜错了，
>    拿完整报错一看才是编码。** 加上 `-encoding UTF-8` 之后三个镜像全绿。

**二、裸容器实测。** 从一个什么都没装的镜像开始，逐层加，看每层走到哪：

| 层 | 装了什么 | 目标 |
|---|---|---|
| L0 | 裸镜像 | T1：`clang --version` 能起来 |
| L1 | `+ make` | T2：`ndk-build` 编出一个 `.so` |
| L2 | `+ JDK + zip + curl/unzip` | （还编不了 APK——缺 `android.jar`） |
| L3 | `+ platforms/android-XX` | T3：`tests/hello-native` 出 APK |

默认在 `ubuntu:24.04` / `ubuntu:22.04` / `debian:12` 上各跑一遍。**结论不是
「能用/不能用」，是「到底还得装什么」**——那句话要写进 README 给用户看，所以
必须是量出来的。

**干净机器要多高配置？很低——低到值得单独说一句。** 这正是这个项目的意义：
编包要台大机器，用包不要。

| | 编包那台（第六节记过） | 用包 / 干净机器测试 |
|---|---|---|
| 内存 | 8 GB 起，16 GB+ 推荐<br>（LLVM 链接阶段 8 GB 以下大概率 OOM） | **~100 MB 峰值** |
| 磁盘 | 40 GB 起，80 GB+ 推荐 | **~4 GB** |
| CPU | 越多越好，编 LLVM 约一小时 | 1 核，全流程几秒 |

实测的数（不是估的）：

| 量的东西 | 结果 | 怎么量的 |
|---|---|---|
| SDK 包解压后 | 30 MB → **62 MB** | 真解压 |
| NDK 包解压后 | 563 MB → **1.9 GB** | `make-ndk-dist.sh` 报的「留下 1.9G」 |
| `clang` 编一个 `.c`（-O2） | **45 MB**，0.5 秒 | 官方 x86_64 NDK 实测，架构不影响数量级 |
| `ndk-build` 全过程 | **46 MB**，0.6 秒 | 同上 |
| `javac` | **85 MB**，1.1 秒 | 等价规模的替代测量，见下 |
| `d8` | 累计 **93 MB** | 同上 |

再加 JDK 装出来约 400 MB、系统本身，**4 GB 磁盘 / 1 GB 内存足够**。

两处得说清楚：

- `javac` / `d8` 那两行是**替代测量**。`make-dist.sh` 有意不打包
  `platforms/`（纯 Java + 数据，用户手上那份直接能用），所以包里没有
  `android.jar`，拿 hello-native 的源码直接编会缺类。改用了一个不依赖
  Android API 的类——hello-native 的 dex 也才 1808 字节、一个类，同一量级。
  （第一次量的时候没注意 `javac` 是 `rc=2` 退出的，那几个数字是**失败退出**
  的峰值，不是编译的峰值，作废重量了。）
- `d8` 脚本里写着 `-Xmx2G`。那是**上限不是预留**，小内存机器上不会因此起不来，
  只要实际用量不超。真不够可以 `d8 -JXmx256M ...`。

所以拿 Oracle Cloud 最小的那档 ARM 实例（1 OCPU / 6 GB）都绰绰有余，
用 docker 跑本节的容器测试也一样——`--rm` 是串行的，峰值就是一个容器
约 2.5 GB 加镜像层。

**没有 docker 就手工做**，别在打包那台上试（那台什么都装过了，测不出东西）。

前半段**只要两个 tar.gz**——那是在模拟真实用户；后半段要编 APK，得再添两样：

```bash
# 1. 一台干净的 ARM64 机器（新开的云实例，或 podman/lxc 裸容器）

# ---- 前半段：只有两个包，别的什么都别拷 ----
# 2. 解压
mkdir -p ~/asdk && tar -C ~/asdk -xzf android-sdk-*.tar.gz \
                && tar -C ~/asdk -xzf android-ndk-*.tar.gz
NDK=$(ls -d ~/asdk/ndk/*/); NDK=${NDK%/}

# 3. L0：什么都不装，先看编译器起不起得来
"$NDK"/toolchains/llvm/prebuilt/linux-aarch64/bin/clang --version
#    报 GLIBC_x.y not found -> glibc 太老，这台装不了，别往下走了
#    报缺 libz.so.1 之类     -> 装上再来，并把它记进依赖清单

# 4. L1：装 make，现场写个五行的工程编个 .so（不需要仓库）
sudo apt install -y make
mkdir -p /tmp/p/jni && printf 'int f(void){return 42;}\n' > /tmp/p/jni/x.c
printf 'LOCAL_PATH := $(call my-dir)\ninclude $(CLEAR_VARS)\nLOCAL_MODULE := x\nLOCAL_SRC_FILES := x.c\ninclude $(BUILD_SHARED_LIBRARY)\n' > /tmp/p/jni/Android.mk
"$NDK"/ndk-build NDK_PROJECT_PATH=/tmp/p APP_ABI=arm64-v8a NDK_APPLICATION_MK=/dev/null
file /tmp/p/libs/arm64-v8a/libx.so    # 该是 ARM aarch64

# ---- 后半段：要编 APK，还差两样 ----
# 5. L2：JDK 和 zip
sudo apt install -y default-jdk-headless zip curl unzip

# 6. L3：android.jar —— **SDK 包有意不含 platforms/**，得自己下一份
#    65 MB，repository2-3.xml 里这个 archive 没有 <host-os>，任何架构通用
curl -fsSLO https://dl.google.com/android/repository/platform-36_r02.zip
mkdir -p ~/asdk/platforms && unzip -q platform-36_r02.zip -d ~/asdk/platforms

# 7. 跑样例工程 —— 这一步要仓库里的 tests/
#    **注意分支**：默认分支上没有这些文件，clone 完得切过去，否则
#    报 tests/hello-native/build.sh: No such file or directory
git clone <本仓库> ~/repo && cd ~/repo && git checkout <开发分支>
ANDROID_HOME=~/asdk ANDROID_NDK_HOME="$NDK" tests/hello-native/build.sh

# 8. 把每一步实际装了什么记下来 —— 那份清单就是「用这个包还需要什么」
```

#### 用这个包还需要什么

第 4 步之前不需要仓库，也不需要 JDK——**解压完 `clang` 和 `ndk-build` 就能编
`.so`**。要编到 APK 才需要下面这些：

| 要什么 | 哪来 | 为什么包里没有 |
|---|---|---|
| `make` | `apt install make` | `prebuilt/` 里那个是 x86 的，丢了；`ndk-build` 会退回系统的 |
| JDK、`zip` | `apt install default-jdk-headless zip` | `javac` / `d8` / `apksigner` 要，本来就是外部依赖，官方 SDK 也一样 |
| `platforms/android-XX`（`android.jar`） | 自己下 `platform-36_r02.zip`，65 MB | **`make-dist.sh` 有意不打包**——纯 Java + 数据，跟架构无关，不该由我们重新分发 |
| 仓库里的 `tests/` | `git clone` | 只是跑样例工程要，真实用户不需要 |

`platforms/` 那条最容易漏。`make-dist.sh` 的原话是「纯 Java + 数据，跟架构无关，
**用户手上那份直接能用**」——这句话对「已经有一套 SDK」的人成立，**对干净机器
完全不成立**，那里没有「手上那份」。这个缺口是写手工步骤时才发现的：原来的
第 5 步直接叫人跑 `hello-native/build.sh`，而它必然会死在
`找不到 android.jar，装一个 platform`。容器测试也因此加了一层 L3。

**验到哪一步，说清楚：**

- **验了**（x86_64 容器里）：第一阶段拿真实的 SDK 包 + 一个从官方 NDK 打的
  包跑通，扫出 47 个 host 二进制、额外依赖清单、glibc 门槛 `2.16`；
  `libgcc_s.so.1` 一开始被误报成「额外依赖」，改掉了——它是 GCC 运行时，
  glibc 自己就依赖它。容器里那段脚本的语法和三态解析（ok / FAIL / 没走到）
  也单独验过。
- **验了**（真的在一台干净 ARM64 机器上手工走了一遍，Ubuntu 24.04 / glibc 2.39 /
  aarch64，全新实例）：

  | 步 | 结果 |
  |---|---|
  | 解压两个包 | 2.0 GB |
  | L0 **什么都不装** | `clang 18.0.2` 直接跑起来 |
  | L1 `+ make` | `ndk-build` 编出 `ARM aarch64` 的 `.so`，带 `BuildID[sha1]` |
  | L2 `+ JDK/zip/curl/unzip` | `javac 21.0.12` |
  | L3 `+ platform-36_r02.zip` | 解到 `platforms/android-36/`，`android.jar` 27 MB |
  | T3 `hello-native` | 一路出 APK，12802 字节，含 `lib/arm64-v8a/libhellonative.so` |

  **L0 那条是这个包最想要的结论**：一台什么都没装的机器，解压完编译器就能跑。

  但**这没测出 glibc 门槛**——那台跟打包机同为 24.04/2.39。门槛要拿 22.04 才测得到。

- **验了**（工具链自足，用探针法在干净机器上钉死）：见下。
- **没验**：**第二阶段的 docker 实际执行仍然没跑过**——写它的机器上 docker
  守护进程连不上。上面那些是手工走的，容器脚本的代码路径本身还没执行过。

##### 「自足」怎么才算证明了

第一版红检查是**错的**，而且踩的正是我们自己补丁里写着的坑。当时的想法是：
把包里的 python3 藏起来、PATH 里塞一个必然失败的假 python3，构建应该炸。

**它没炸。** 原因 `patches/ndk/0005` 的注释里就写着：

> Every use of HOST_PYTHON goes through `$(shell)`, and `$(shell)` returns an
> empty string for a missing command without failing.

假 python3 存在且可执行 → `command -v python3` 找得到 → `HOST_PYTHON` 被设成它 →
`$(error)` 不触发 → 调用失败后 `$(shell)` 只返回空串 → 构建照样「成功」。
**红检查没红，那绿检查的「成功」就什么都证明不了。**

换成探针：PATH 上放一个 `python3`，它把调用记进日志然后 `exec` 转发给真的。
判据从「构建成败」改成「**它有没有被调用**」：

| | 包里的 python3 | PATH 上的探针 | 说明 |
|---|---|---|---|
| A | 在 | **0 次** | `ndk-build` 用的是包里那份 |
| B | 藏起来 | **3 次**（`extract_manifest.py` ×2、`ldflags_to_sanitizers.py` ×1） | 这条路径确实要 python |

**两条都要有**。只有 A 说明不了问题——也许 `ndk-build` 根本没调 python；
B 补上了这一半。而且这一条自己就先踩了个坑：原来只查 `command -v docker`，
  客户端在、守护进程没跑的时候，每个镜像安静地印一片「（没走到）」，
  看着像跑过了。现在改成查 `docker info`，连不上就明说「这一段没测」。

### 不做什么

- 不改 Android 的构建行为。**产物必须和官方 x86_64 版行为一致**，只是换了 host 架构。
- 不 fork AOSP。只做「拉源码 → 为 aarch64 host 构建 → 按 NDK/SDK 目录约定摆好」的编排。
- 不碰 Windows / macOS ARM——Google 已经发了 macOS ARM 版。

---

### 空白还剩多大——从官方清单数出来的

「填补 Google 不发 ARM SDK/NDK 的空白」要有个尽头，那个尽头得从**官方发布清单**
数，不能凭感觉。拿 `repository2-3.xml` 数一遍：

```
275 个 remotePackage
├── 73 个没有 <host-os>       跟架构无关，任何机器都能用 —— 不在范围内
└── 202 个按平台分发           每一个的 linux archive 都是 x64，**没有一个 aarch64**
```

那 202 个去掉版本重复，**组件类型只有 9 类**：

| 组件 | 官方 linux 版 | 我们 | 判断 |
|---|---|---|---|
| `platform-tools` | x64 | ✅ | 做了 |
| `build-tools` | x64 | ✅ | 做了 |
| `ndk` / `ndk-bundle` | x64 | ✅ | 做了 |
| `cmake` | 标 `(any)`，内容是 x86_64 ELF | ❌ | **多半不用我们编**——见下 |
| `cmdline-tools` | `(any)` | — | **不用做**：解开来 108 个文件、**0 个 ELF**，全是 jar 和 shell 脚本，官方那份在 ARM 上直接能用 |
| `emulator` / `emulators` | x64 | ❌ | 真空白，**决定不做**（2026-08-30），理由见路线图第 7 条 |
| `skiaparser` | x64 | ❌ | Android Studio 的 Layout Inspector 用 |
| `extras;google;auto` | x64 | ❌ | Android Auto 桌面模拟器，很边缘 |
| `build;templates` | `(any)` | — | 跟架构无关，不用做 |

> ⚠️ **「官方包里有」不等于「我们必须编」。** 判据得再往下问一层：
>
> | | 例子 | 怎么办 |
> |---|---|---|
> | AOSP／Google 独有，没有替代品 | `aapt2`、`adb`、`fastboot`、`aidl`、`dexdump`、NDK 工具链 | **只能我们编** |
> | 上游开源项目 + **AOSP 特有的封装** | `mke2fs`、`make_f2fs`（都链 `system/core/libsparse`，发行版那份没有 sparse image 支持） | 也只能我们编 |
> | 标准开源工具，发行版有 ARM 版 | `cmake`、`ninja`、`lldb`、`clangd`、`glslc` | 先验系统的能不能用 |
> | 纯 Java／跟架构无关 | `cmdline-tools`、`platforms/` | 官方那份直接能用 |
>
> 这条踩过两次（`cmake`、`lldb`），详见 [docs/LESSONS.md](LESSONS.md)。

#### 回头看：已经编的里面，有没有其实不用编的

按上面这条判据把**已经编出来的**逐个回溯（源码来自哪棵树、链了哪些 Android
特有的库），答案是**有一个：`sqlite3`**。

它是唯一一个 `cmake/*.cmake` 里**一个 Android 库都没链**的——只有
`external/sqlite/dist` 的 amalgamation 加一堆 `-D`。装一份发行版的对比
（发行版那一列是 2026-08-28 实测记下的；那份 `sqlite3` 现在已不在这台机器上，
所以 2026-08-29 复测时只重测了我们自己这一列）：

| | 我们（2026-08-28，无 ICU） | 我们（2026-08-29，**加了 ICU** ） | Ubuntu 24.04（3.45.1） |
|---|---|---|---|
| `icu_load_collation` | `no such function` | **函数在**（`ucol_open(): U_FILE_ACCESS_ERROR`） | `no such function` |
| `upper('äöü')` | `äöü` | **`ÄÖÜ`** | `äöü` |
| FTS5 / RTREE | 没开 | 没开（官方也没开） | **有** |

> ⚠️ **这一节原来的结论被自己后来的工作推翻了，留在这里当记录。**
>
> 2026-08-28 写的是：「行为一模一样，发行版的功能反而更多、版本更新」，
> 因此「`sqlite3` 其实不用自己编」。那个结论**当时是对的**——因为我们那份
> 还没有 ICU，跟发行版一样。
>
> 2026-08-29 把 ICU 补上之后，中间那一列跟右边那列**不再一样**了：
> `icu_load_collation` 和 `upper('äöü')` 都是发行版给不了的。
> 所以「自己编」的理由从「只为了跟官方的建库默认值一致」变回了实打实的
> **功能差别**：`apt install sqlite3` 拿不到带 ICU 的那个。
>
> 但有一条**没有**被推翻，还得留着：**带 ICU 是 Google 特意加的，不是标准
> SQLite 的默认**。所以当初那句纠正依然成立——「我们缺 ICU」不该记成
> 「我们比标准少了什么」，而是「官方那份多做了一件事，我们跟上了」。

其余已编的都站得住：`mke2fs` / `make_f2fs` 链 `libsparse`（Android 的 sparse
image 格式，发行版那份没有）；`aapt`／`aapt2`／`aidl`／`dexdump`／`etc1tool`／
`hprof-conv`／`split-select`／`zipalign`／`adb`／`fastboot` 全是 AOSP 独有；
LLVM 工具链见第四节（系统 clang 的默认值不对，薄壳那一整节）；CPython 是为了
**工具链自足**（补丁 0005 那个静默降级）。

**组件内部**还欠的（都在各自脚本的名单里记着，且有自检防止名单写错）：

| 在哪 | 欠什么 | 记在哪 |
|---|---|---|
| NDK `bin/` | `clang-tidy`、`clangd`、`lldb`×3、`llvm-bolt`、`merge-fdata`、`sancov`、`sanstats`、`yasm` 等 13 项 | `tools/build-llvm.sh` 的 `KNOWN_MISSING` |
| NDK 其他 | `shader-tools/`（`glslc`、`spirv-*`，装机时由 `link-system-tools.sh` 从系统接进来）、`libsimpleperf_report.so`（bionic/glibc 混不进一个进程，另一条线）、`prebuilt/` 的 `make`/`yasm`（退回系统 `make`，实测能用） | `tools/make-ndk-dist.sh` |
| `build-tools` | 9 个 RenderScript 相关 | `tools/make-dist.sh` 的 `KNOWN_WONTDO`（Android 12 起废弃，**决定不做**） |

### 按什么顺序做

**先把「只能我们编」这一栏收缩到位。** 按上面那条判据把剩下的逐个查过
（`apt-cache policy` + Ubuntu 官方包库确认 **arm64** 真的有），结果是：

| 项 | Ubuntu 24.04 arm64 | 结论 |
|---|---|---|
| `cmake` / `ninja` | ✅ | 不用编 |
| `lldb`（host 端） | ✅ `lldb-18` | 不用编 |
| `clang-tidy` / `clangd` | ✅ `clangd-18` | 不用编 |
| `glslc` / `spirv-*`（`shader-tools/`） | ✅ 七个架构都有 | 不用编 |
| **`simpleperf`** | ❌ **源里没有** | **只能我们编**（AOSP `system/extras/simpleperf`） |

> 查的时候差点又栽一次：本机 `apt-cache show glslc` 报 `Architecture: amd64`，
> 那只是**这台 x86_64 机器的索引**里能装的那份，**不能推断 arm64 源里没有**。
> 得去 Ubuntu 官方包库看架构列表才作数。**「本机查出来的结论套到目标架构上」
> ——这个项目从第一行代码起要防的就是这个，查自己的路线图时照样会踩。**

所以**剩下的工作性质变了：主要不是「编」，是「接」和「验」**——把发行版已有的
那些摆到 NDK/SDK 期望的路径和目录名下，然后验证 AGP / `ndk-gdb` 认不认。

1. **发 Release。** ——**最要紧，而且不是技术活。**（`main` 已经合进去了，
   现在 clone 拿到的是完整仓库；但要拿到能直接用的包，还是得自己跑一小时 LLVM。）
   空白不是「东西没做出来」，是「别人拿不到」。

   > ⚠️ **发之前必须重新出包，别拿手边现成的那份。** 2026-08-29 踩到：机器上那个
   > NDK 包是 8/28 19:29 打的，而「加兼容软链 `linux-x86_64 -> linux-aarch64`」
   > 那次提交是当天 22:41 —— **包比修复早三小时**，里面根本没有那条软链，
   > AGP 调 `llvm-strip` 时直接 `No such file or directory`。
   > 打包脚本改过之后手边的包就是旧的，而它长得跟新的一模一样。

   > ⚠️ **NDK 拿哪棵树打包，看清楚再动手。** 2026-08-29 栽过一次：
   > 当时那棵「官方 NDK 原样备份」树里的工具链是**降 glibc 门槛
   > 之前**那版（clang/lld 要 `GLIBC_2.38`），拿它打出来的包在 22.04 / Debian 12
   > 上全起不来 —— 而且**它跟好的那版长得一模一样，只有 `llvm-readelf` 看得出来**。
   > 降过门槛的那套当时只存在于装好的 SDK 里，机器上其它副本全是 2.38。
   > 正确的输入树是「备份树 + 从装好的 SDK 移植回来的工具链」那一棵（本文里叫
   > `ndk-repack`；具体放哪儿看你自己的 `$WORK`）。**打完包别只看脚本打勾，量一遍**：
   >
   > ```bash
   > tar -xzOf <包> --wildcards '*/bin/clang-18' > /tmp/c && \
   >   llvm-readelf --dyn-symbols /tmp/c | grep -oE 'GLIBC_2\.[0-9]+' | sort -t. -k2 -n | tail -1
   > # 该是 2.34；自带的 libpython3.11.so 是 2.35，那是全包最高的一个
   > ```

   **暂缓的理由**（2026-08-29）：仓库还是私有的，而**私有仓库的 Release 走
   存储配额**。等开源之后再发。

   ### 发之前照这张单子走

   **0. host 那三样要在旧发行版的容器里编**，否则门槛会跟着打包机跑回 2.38：

   ```bash
   tools/build-in-container.sh tools/build-python.sh --build
   tools/build-in-container.sh tools/build-llvm.sh   --build   # 实测 88 分钟（4 核 ARM64）
   HERMES_TAG=... tools/build-in-container.sh tools/build-hermesc.sh --build
   ```

   > **顺序要紧，上面那三行不能换。** `build-llvm.sh` 最后会把 python3 一并装进
   > `$WORK/out/llvm/…/python3`，而它是**从 `$WORK/out/python3/<tag>` 拷的**
   > —— 也就是 `build-python.sh` 上一次的产物（`tools/build-llvm.sh:356`）。
   > 那份要是旧的（宿主编的 2.38），装出来就是 2.38，**哪怕 clang / lld 都是 2.34**。
   > 2026-08-30 实测撞上：LLVM 在容器里编完，`out/llvm` 里 `libpython3.11.so.1.0`
   > 仍要 `GLIBC_2.38`。SDK 包不受影响（只从这里取 `lld`），但**下一次拿
   > `out/llvm` 打 NDK 包就会把 python 从 2.35 退回 2.38**。
   > 补救不用重编 LLVM（88 分钟）：容器里跑一次 `build-python.sh`，
   > 再把 `$WORK/out/python3/<tag>` 拷成 `$WORK/out/llvm/<tag>/python3` 就行 ——
   > 那正是 `build-llvm.sh` 自己那一步做的事。
   >
   > 另外两条实测出来的坑：
   > - **容器里只看得见 `$REPO`（只读）和 `$WORK`（可写）**。`build-llvm.sh` 要的
   >   NDK 供体必须放在 `$WORK` 里（`$WORK/android-ndk-<版本>/`），放 `/opt` 下
   >   容器根本看不到，报「找不到 NDK」。
   > - **构建目录要是宿主配过的，先挪开**（`$WORK/llvm/build`）。它的 CMakeCache
   >   记着宿主的编译器路径，容器里复用会编出混血产物。

   **1. 重新出包，三个都出。** 别用手边现成的（上面那条警告）。

   ```bash
   tools/make-dist.sh                     # 要一份官方 SDK 借 jar，见脚本里的守卫
   tools/make-ndk-dist.sh /path/to/官方NDK  # 输入必须是官方原版 + 我们的工具链
   tools/build-hermesc.sh                 # 末尾自己打 tar.gz
   ```

   **1b. 还要出 `sdkmanager` 仓库**（`tools/make-repo.sh --verify`）。

   > **这不是加分项，是发布物的一部分。** 用户在 x86 上做的事几乎都从
   > `sdkmanager` / Android Studio / Gradle **自动下载**开始；只发 tar.gz 的话，
   > 每台机器要手动铺、升级要手动换，而且 AGP 触发的自动下载会把 x86_64 的
   > 东西塞回来。仓库这条路让用户的工程**一个字都不用改**。
   >
   > 产物是 `$WORK/repo`（两个 zip + `repository2-3.xml`，约 59 MB），
   > 静态托管即可（GitHub Pages 就行）。`--verify` 会真起 http 服务、
   > 真让 `sdkmanager` 装一遍、再把装出来的二进制真跑一次。

   **2. 三个包，各自的位置不一样，说明里要写清楚：**

   | 包 | 解到哪 | 备注 |
   |---|---|---|
   | `android-sdk-linux-arm64-<ver>.tar.gz` | `$ANDROID_HOME` | |
   | `android-ndk-<ver>-linux-aarch64.tar.gz` | `$ANDROID_HOME` | 含 `simpleperf` 的 host 那半 |
   | `hermesc-<ver>-linux-aarch64.tar.gz` | **不进 `$ANDROID_HOME`** | React Native 才要；`hermesCommand` 指过去 |

   **3. tag 怎么起。** 这三个包的版本号来自三棵不同的树（SDK 跟
   `platform-tools-*`、NDK 跟 `r27b`、hermesc 跟 RN 的
   `.hermesv1version`），**不能用一个号冒充它们同步**。用日期做仓库自己的
   release 号，包名里各自带各自的版本：`v2026.08.29` 这种。

   **4. 说明里必须有的四样**（少一样就会有人来问）：

   - **每个包的 sha256**，跟 `docs/INSTALL.md` 里写的对得上
   - **glibc 门槛**：**逐个二进制量出来写，别照抄打包机的版本**
     （`llvm-readelf --dyn-symbols`，取全包最大值）。2026-08-30 实测：
     **SDK 包 2.34、NDK 包 2.35**（NDK 那个 2.35 来自自带的 `libpython3.11.so`，
     clang / lld 都只要 2.34）。也就是 **22.04 和 Debian 12 都能用**。
     （`aapt2` / `adb` 那些是静态 bionic，一个 GLIBC 符号都没有，不吃这条。）

     > SDK 那个 `build-tools/*/lld-bin/lld` 一度是 **2.38**（在 22.04 / Debian 12 上
     > 直接起不来）—— 因为它来自 `$WORK/out/llvm`，而那份是宿主 24.04 上编的。
     > 2026-08-30 照第 0 步在容器里重编 LLVM（88 分钟）才降下来。
     > **别只看符号表就下结论，进容器真跑一次**，两个发行版各一组对照：
     >
     > | | Ubuntu 22.04 (2.35) | Debian 12 (2.36) |
     > |---|---|---|
     > | 新的 | `LLD 18.0.2 (compatible with GNU linkers)`，rc=0 | 同左 |
     > | 旧的（留作对照组的那份 `lld`，降门槛之前编的） | `version GLIBC_2.38 not found`，起不来 | 同左 |
     >
     > 判据用**输出**不用退出码：`lld --version` 本身就退 1（它是 generic driver，
     > 要求以 `ld.lld` 之类的名字调用），拿退出码判会把好的也判成坏的。
     > 正确的调法是 `lld -flavor gnu --version`，看有没有打出 `LLD `。
   - **已知缺陷**，别藏：`libsimpleperf_report.so` 没有；`simpleperf` 读**设备**
     录的 perf.data 没验过。（原先列在这里的两条 —— `aapt2` 不认 `--选项=值`、
     `simpleperf` 录的文件自己读不回 —— **都已经修了**，见第 3 条和第 5 条，
     别再写进发布说明。）
   - **一条能自证的命令**，让人下完就能确认没拿错东西：
     `tools/make-downstream-sdk.sh` 会把每个原生件真跑一遍

   **5. 别忘了 `platforms/` 和 `licenses/` 不在包里**，也不该在（第七节那张表）。
   **glibc 门槛已经压到 `GLIBC_2.34`**（2026-08-29）：host 工具改在
   `ubuntu:22.04` 容器里编（`tools/build-in-container.sh`），从 `2.38` 降下来。
   实测三个裸容器 —— `ubuntu:24.04` / `ubuntu:22.04` / `debian:12` —— **都能从零
   编出 APK**。发包时说明里那条门槛记得跟着改。

2. **把系统工具接进来，逐个验。** 这是一批，可以一起做，都是「摆位置 + 验版本」：

   | 接什么 | 摆到哪 / 怎么配 | 验什么 |
   |---|---|---|
   | `cmake` `ninja` | `local.properties` 的 `cmake.dir=/usr`，或摆进 `$ANDROID_HOME/cmake/<AGP 要的版本>/` | AGP 认不认版本号（系统 3.28 vs 常要的 3.22） |
   | `lldb` | 软链到 `toolchains/llvm/prebuilt/linux-aarch64/bin/lldb` | 能不能连上包里已有的 `lldb-server`（设备端那半**已经在包里**） |
   | `clang-tidy` `clangd` | 同上，`bin/` 底下 | IDE / `APP_CLANG_TIDY=true` 认不认 |
   | `glslc` `spirv-*` | `shader-tools/linux-aarch64/` | 编一个 Vulkan shader |

   **这一条已经做出来了：[`tools/link-system-tools.sh`](../../tools/link-system-tools.sh)**
   ——四组挨个接、挨个**真验**（不是 `--version` 就算完）：拿 NDK 的
   `android.toolchain.cmake` 真交叉编一个 `.so`／编个 GLSL 过 `spirv-val`／
   让 lldb 真读一个 Android 的 `.so`／clang-tidy 对着 NDK 的 sysroot 解析
   Android 头文件。`--check` 只报告不动文件，已有的东西一律不覆盖。

   **2026-08-29 在真 aarch64 机器上跑完，四组全绿**（Ubuntu 24.04 arm64，
   SDK `/opt/android-sdk`，NDK r27.1.12297006）：

   | 组 | 系统那份 | 真做了什么 |
   |---|---|---|
   | `cmake` `ninja` | 3.28.3 / 1.11.1 | 拿 `android.toolchain.cmake` 交叉编出 arm64-v8a 的 `.so`（`file` 认成 ARM aarch64）。**注意这一条当时验的是机器上那份官方 NDK**，见下 |
   | `glslc` `spirv-*` | glslc 2023.8 / spirv-tools 2025.1~rc1 | GLSL → 428 字节 SPIR-V，`spirv-val` 通过 |
   | `lldb`（host） | 18.1.3 | 读得懂 sysroot 里 Android 的 aarch64 `libc.so` |
   | `clang-tidy` `clangd` | 18.1.3 | 对着 NDK sysroot 解析 `<android/log.h>`，无 `error:` |

   在此之前 x86_64 上也全绿（验的是「系统工具跟 NDK 配不配」，跟工具链自身架构
   无关），变异测试同样过：挪走 sysroot → clang-tidy 那条红，挪走
   `android.toolchain.cmake` → cmake 那条红。

   **连设备调试那一步 2026-08-29 验掉了**（当时这里写的是「仍然没验，要真机 +
   真设备」）。设备是一台 vivo V2337A（Android 16 / SDK 36 / arm64-v8a），
   隔着 ssh 反向隧道接进这台云机器。脚本是 `tools/verify-lldb-device.sh`：
   把 NDK 的 `lldb-server` 和一个靶子（我们自己编的 `aapt2`，**它是 Android
   目标二进制，在设备上跑得动**）推到 `/data/local/tmp`，`adb forward`，
   host lldb 隔着 adb 连上去——**停住、读了 pc（`0x2e1c00`）、继续到正常退出**，
   连跑三次都过、pc 一致。判据跟 `link-system-tools.sh` 里那步环回**完全一致**，
   两边可以直接对照。

   同一台设备上 `tests/hello-native/build.sh --install` 也跑通了：logcat 里
   `RESULT native ok: 64-bit, built Aug 29 2026 | 20+22=42`。APK 是这台 ARM64
   机器用我们自己的工具链从头编的。

   > 写这个脚本时红了四次，四次都是真问题，不是脚本写错字（细节在
   > [docs/LESSONS.md](LESSONS.md) 的教训表）：**① 就绪判据假绿**（拿「本地端口连得上」
   > 判设备就绪——`adb forward` 一建好本地就接受连接，设备侧有没有监听它不管）；
   > **② `| grep -q` 撞上 `pipefail`**（命中即退出→上游 SIGPIPE→管道非 0→
   > 「找到了」被判成「没找到」，表里早有这条，又踩一次）；
   > **③ `adb forward` 的口开在跑 adb 服务器那台**（走 ssh 隧道时是笔记本，不是本机）；
   > **④ 探测把只能连一次的服务用掉了**（`lldb-server gdbserver` 只接受一个客户端）。
   > 反过来说：这四次红，也就是这条检查「会红」的实证——它不是只会打勾的摆设。

   > ⚠️ **这份「全绿」有个当时没看出来的盲区，隔天跑 Gradle 才炸出来。**
   > `link-system-tools.sh` 是对着 `$ANDROID_HOME` 里的 NDK 验的，而那台机器上
   > 那份是**官方 NDK**（`source.properties` 没被 `make-ndk-dist.sh` 改过、
   > 我们的补丁也没打上，只是旁边多挂了一份 aarch64 工具链目录），
   > **不是我们打出来的那个包**。换成我们自己打的包，同一条 cmake 检查**是红的**——
   > 包里的 `source.properties` 被改过一个字段，NDK 自带的 toolchain 文件读不了
   > 版本号（下面第 3 条）。
   >
   > **「系统 cmake 配不配 NDK」和「配不配我们的 NDK」是两个问题，当时只验了前一个。**
   > 判据没错，指错了对象。这跟「拿本机查出来的结论套目标架构」是同一个形状，
   > 只是这次错位的不是架构，是**哪一份 NDK**。
3. **我们这份 `aapt2` 的参数解析器不认 `--选项=值`。已经修了**
   （`patches/aapt2/0001-flag-equals-value.patch`，2026-08-29）。

   `cmd/Command.cpp` 的解析循环是逐字比对 `arg == flag.name`，**只认空格形式**。
   而 AGP 的 `optimizeXxxResources` 用等号形式：

   > **跟 AGP 版本有关，别当成通用结论。** 实测：**AGP 9.3.2** 传等号形式，
   > 未打补丁的 aapt2 中招；同一台机器上下游工程用 **AGP 8.12.0**，同样跑了
   > `:app:optimizeReleaseResources`、同样是未打补丁的 aapt2，**产出的 APK
   > 完好**（`AndroidManifest.xml`、`resources.arsc` 都在，`dump badging` 读得出）。
   > 所以它是**升级 AGP 时才会撞上的雷**，而且撞上时是静默的 —— 这正是要提前
   > 修掉的理由，不是「反正现在没事」的理由。

   ```
   aapt2 optimize <ap_> --shorten-resource-paths \
         --resource-path-shortening-map=<路径> -o <输出>
   ```

   这个选项我们的 aapt2 本来就支持，差的只是写法。
   **真正伤人的是 AGP 把这个失败吞了**：构建报 `BUILD SUCCESSFUL`，
   而 APK 里 `AndroidManifest.xml` 和 `resources.arsc` 全没有 —— 一个装上去
   必崩的包，全绿。

   补丁在第一个 `=` 处切一刀；`--开关=值` 这种（选项本来不带值）**明确报错**，
   不静默忽略等号右边 —— 那会是同一类静默失败。

   **判据不是「构建成功」**（这个 bug 的要害就是它报成功）：

   | | 打补丁前 | 打补丁后 |
   |---|---|---|
   | AGP 那条原样命令 | 退出 1，`unknown option`，无产物 | 退出 0，产物 2644 字节 |
   | `resources-release-optimize.ap_` | **根本不存在** | 2644 字节 |
   | APK 里的清单和 arsc | **全没有** | 都在 |
   | 空格形式 `--选项 值` | 好使 | 照样好使（没为新写法牺牲旧的） |

   `tests/gradle-build.sh` 因此**不再写死那个绕行开关**：它拿这个选项空跑一次
   探一下，认就照常开着 optimize，不认就自动关掉并说清为什么。两支都验过。

   SDK 包已重打（`sha256 9501e388…`），包里的 aapt2 带这个修复。

4. **`hermesc`（React Native 的 JS 字节码编译器）。已经做出来了 ——
   `tools/build-hermesc.sh`。** 它带出了判据表上原本没有的一类。

   React Native 打 release 包时不把 JS 以源码塞进 APK，要先编成 Hermes 字节码
   （`.hbc`）。干这活的 `hermesc` 来自 npm 的 `hermes-compiler` 包，而那个包
   **一共只发三个二进制**（实测最新版 `250829098.0.17` 解开就是这三个）：

   ```
   package/hermesc/linux64-bin/hermesc     ELF x86-64, statically linked
   package/hermesc/osx-bin/hermesc
   package/hermesc/win64-bin/hermesc.exe
   ```

   **没有 ARM Linux。** RN 的 Gradle 插件自己把这条写死了
   （`@react-native/gradle-plugin` 的 `utils/PathUtils.kt:189`）：
   `if (Os.isLinuxAmd64()) return "linux64-bin"`，否则
   `error("OS not recognized. Please set project.react.hermesCommand …")`。

   **判据上它是新的一类**：不是 Google/Meta 私有（Hermes 是 MIT 开源的），
   也不是「发行版有 ARM 版」（`apt` 里没有）—— 是**上游只为那三个平台出包**。
   docs/LESSONS.md 那张表因此多了一行。

   | 做完了什么 | |
   |---|---|
   | 源码 | `facebook/hermes`，tag `hermes-v250829098.0.17` |
   | 版本怎么定的 | **不是猜的**：RN 包里 `sdks/.hermesv1version` 明写着这个 tag，`sdks/hermes-engine/version.properties` 的 `HERMES_VERSION_NAME` 与之一致，而 npm 上 `hermes-compiler` 的版本号就是去掉 `hermes-v` 前缀那串 |
   | 产物 | 4 182 048 字节，aarch64 的 **glibc host** 二进制 |
   | 怎么接进 RN | 三条官方路径任选，**都不用打补丁**：`react { hermesCommand }` / `REACT_NATIVE_OVERRIDE_HERMES_DIR` / `sdks/hermes/build/bin/hermesc`。解析顺序见插件的 `PathUtils.kt:50`；**`hermesCommand` 非空时优先级最高，另外两条会被跳过** |
   | 发布形态 | **单独一个 `hermesc-<版本>-linux-aarch64.tar.gz`**，不塞进 SDK/NDK 那两个包 —— 它不是 Android SDK 的组件，不该出现在 `$ANDROID_HOME` 里。包内是 `<版本目录>/build/bin/hermesc`，**这个结构正好是 `REACT_NATIVE_OVERRIDE_HERMES_DIR` 要的形状**，同一个文件也可以直接被 `hermesCommand` 指 |

   > **「`npm install` 会覆盖掉，那移植还有什么意义」** —— 这个问题问对了一半：
   > 被覆盖的是**「把二进制拍进 `node_modules`」这种装法**，不是移植本身。
   > RN 官方给了 `hermesCommand`，它优先级最高、`npm install` 冲不掉，而且
   > 很多 RN/Expo 工程的 `android/app/build.gradle` 里**本来就有这一行**
   > （只是指向 npm 那份 x86_64），改的是它的值。
   >
   > 没有这份移植，ARM64 Linux 上打 RN release 只剩两条路：装 qemu 模拟
   > x86_64，或者送去云端编。而 qemu 恰恰是这台机器上不该有的东西
   > （第五节第 1 条：它会让「真跑一次」那类检查假绿）。

   **它跟其余 14 个工具都不同的一点**：`hermesc` 是 **host 工具**（跑在打包机上，
   吃 `.js` 吐 `.hbc`），所以是 glibc 构建，跟 `tools/build-llvm.sh` 同类，
   **不走 `build-common.sh` 那个静态 bionic 骨架**。跟 simpleperf 那次撞上的
   LLVM 是同一个形状。

   验收四步，最要紧的是第四步：**跟官方那份逐字节比对**（第五节第 6 条要的那种）。
   同一份 JS（66 KB、三组参数：无 / `-O` / `-g`），我们编的和官方编的
   **`.hbc` 逐字节一致**。官方只发 x86_64，所以这一步要么在 x86 机器上跑，
   要么本机装 qemu-user；**跑不了时脚本明说「这一条没验过」，不当过也不报错**。

   > 这条比对的边界，实测出来的，别高估它：
   > - `hermes-compiler` 的相邻补丁版（`250829098.0.0` vs `.0.17`）**出的字节码一样**，
   >   所以它证明不了「我们编的正是 pin 的那一版」——那由 tag 保证。
   > - 别的版本系列（`0.14.0`、`260318099.0.1`）的 linux64 二进制是**动态链接**的，
   >   qemu-user 跑不起来（`rc=126`）；能比的这版恰好是静态链接的。
   > - 反证做过：换一份输入，报 15 994 字节不同 —— 检查会红。

5. **`simpleperf` 的 host 那半。已经做出来，而且进包了。** 发行版没有、只能我们编的。
   （之前这里写「唯一」——`hermesc` 出现之后不成立了，那是另一个原因造成的
   「只能我们编」，判据见上一条。）
   设备端那半（`bin/android/<abi>/`，5 个 ABI）包里已经有了，缺的是
   `bin/linux/x86_64/` 那两个文件：`simpleperf`（5.3 MB）和
   `libsimpleperf_report.so`（5.3 MB，python 脚本用 ctypes 加载它）。

   **2026-08-29 做了一次实查**（照 `Android.bp`，不是照别人的 CMake）。源码确实在
   `system/extras/simpleperf`，而那棵树我们已经有了 —— `extras` 子模块是稀疏检出的，
   之前只放出了 `ext4_utils`，一条命令就能把它加进来：

   ```bash
   git -C <WORK>/aapt2/submodules/extras sparse-checkout add simpleperf
   ```

   host 那两个产物来自 `simpleperf_ndk` 和 `libsimpleperf_report`，两个都套
   `simpleperf_static_libs` 这组 defaults。**18 个依赖逐个查过在不在我们已有的树里：**

   | 有 | `libsimpleperf_etm_decoder` `libsimpleperf_regex`（simpleperf 自己）、`libbase` `liblog` `libutils` `libcutils`、`libprotobuf-cpp-lite`、`libziparchive`、`libzstd`、`libunwindstack`、`libdexfile_static` |
   |---|---|
   | **没有，得新取（6 棵）** | `external/OpenCSD`、`external/rust/crates/rustc-demangle` + `…/rustc-demangle-capi`（后者才定义 `librustc_demangle_static`）、`system/libprocinfo`、`external/lzma`（`liblzma`，是 7-Zip SDK 那套，**不是** `external/xz` —— 那个仓库不存在）、`external/libevent`。六个都带 `platform-tools-35.0.2` 这个 tag，跟其余子模块 pin 得上，不用偏离 |
   | NDK 自带 | `libz` —— sysroot 里就有 `libz.a` |
   | 查出来是别的东西 | `libsimpleperf_readelf` —— 名字像 AOSP 的目标，其实 simpleperf 是**直接 include LLVM 的头**（`llvm/Object/ELFObjectFile.h`、`llvm/Support/MemoryBuffer.h`）。而 llvm-project 那棵树 `build-llvm.sh` 本来就在取 |

   > ⚠️ 头一版这里写的是「`liblzma` `libevent` `libz` 发行版能顶」——**那只对
   > glibc host 构建成立**。我们走的是静态 bionic（跟其余 12 个工具一样），
   > 发行版的 glibc 库一个都用不上，所以缺的树是 5 棵不是 3 棵。
   > **判据从「有没有这个库」变成「有没有这个 ABI 的这个库」，答案就不一样了。**

   **所以规模上它跟 `adb` 是一个量级**（新取 6 棵树 + 链 LLVM 的静态库），
   而且**卡着两个得先定的取舍**：

   - `rustc_demangle` **是硬需求，不是可选项**：`libunwindstack/Demangle.cpp:39`
     和 `simpleperf/dso.cpp:292` 都无条件调用它，链接时必须有真实现。
     决定是**引 Rust 工具链、不塞空实现**（Ubuntu 24.04 的 apt 里就有 `rustup`，
     不用 `curl | sh`；再 `rustup target add aarch64-linux-android`）。
     代价是这个项目多一个构建期依赖，**要写进 INSTALL/README 的前置条件**。
   - `libopencsd_decoder` 照官方补齐，不砍 ETM。

   **还有一处是做到一半才发现的，它改变了做法：LLVM 得再编一遍。**
   `read_elf.cpp` 直接 include `llvm/Object/ELFObjectFile.h`，而
   `tools/build-llvm.sh` 编的是 **host 工具链（glibc）** —— 那份静态库链不进
   静态 bionic 的目标二进制。所以要拿 NDK 的 toolchain 文件把 LLVM 的
   `Object`/`Support` **交叉编到 `aarch64-linux-android`**（用 host 的
   `llvm-tblgen` 做 `LLVM_NATIVE_TOOL_DIR`，只编那几个库，481 个编译单元）。
   **「我们已经编过 LLVM 了」和「我们有这个 ABI 的 LLVM」是两回事** ——
   跟前面 `liblzma` 那条同形。

   **进度（2026-08-29）：编出来了。** 照 `adb` 那次分轮的做法，两轮做完。

   ```bash
   tools/build-simpleperf.sh --fetch     # 七棵树
   tools/build-simpleperf.sh --build     # 预备件 + 全部依赖 + simpleperf
   tools/build-simpleperf.sh --verify    # 三步验收
   ```

   产物 **5 108 192 字节**，静态 bionic 的 aarch64 可执行文件
   （官方那份 host 二进制是 5 305 088，量级一致）。验收三步：
   五个核心子命令都在；**真录了一段**（2 个采样，`perf_event_open` 那条路通）；
   `inject` 在且二进制里有 OpenCSD 的痕迹（ETM 那半链进去了）。

   **进包了**（2026-08-29）：`tools/make-ndk-dist.sh` 把它装到
   `simpleperf/bin/linux/aarch64/`，再补一条 `x86_64 -> aarch64` 的软链 ——
   simpleperf 自己的 python 脚本把 host 目录**写死成 x86_64**
   （`simpleperf_utils.py` 里 `'x86_64' if sys.maxsize > 2**32 else 'x86'`，
   跟机器架构无关），跟 `prebuilt/linux-x86_64` 那条软链同一个道理。
   **没有新加检查**：`is_host_pos()` 里本来就有 `simpleperf/bin/linux/*/*`，
   所以验一（架构）和验六（真跑一次）自动伸到了这个新位置 —— 数字跟着动了，
   107→108 个 host ELF、24→25 条软链、32→33 个真跑过的二进制。

   自己补的目标（源码清单全部照抄各自的 `Android.bp`）：`liblzma`、`libevent`、
   `libprocinfo`、`libopencsd_decoder`、`libasync_safe`、`libdexfile_support`、
   `libunwindstack`、`libsimpleperf_regex`、`libsimpleperf_etm_decoder`、
   `libsimpleperf`（47 个源文件 + 3 个 `.proto` + 一个 genrule）、`simpleperf`。

   > **曾经有一处真缺陷：录出来的 `perf.data` 它自己读不回。已经修了**
   > （`patches/simpleperf/0001-skip-empty-meta-info.patch`）。
   >
   > `cmd_record.cpp:2146` 那段在 `#if defined(__ANDROID__)` 里写五个
   > `android_*` / `product_props` 键，值取自 `ro.*` 属性。我们这份是 Android
   > 目标、跑在 Linux 上，没有属性服务，五个全是空串；而
   > `record_file_reader.cpp:742` 把**空值判成文件损坏** —— 一个空值就让整个
   > `perf.data` 读不了。官方 host 版是 glibc 构建，不定义那个宏，根本不写这几个键。
   >
   > 修在 `WriteMetaInfoFeature`（所有 meta info 的唯一出口）：**空值的键一个都
   > 不写**。真设备上是 no-op（那几个值非空），在这里则跟官方 host 版行为一致。
   >
   > 判据是往返，不是「没报错」：
   >
   > | | 打补丁前 | 打补丁后 |
   > |---|---|---|
   > | `record` | 说 `Samples recorded: 2`，文件也写出来了 | 同 |
   > | `report -i` 同一个文件 | `invalid meta info` | **读出 `Samples: 2`**，带符号的完整 profile |
   >
   > `tools/build-simpleperf.sh --verify` 现在把这条往返做成了第 2 步，
   > 而且**判据是真读出采样数**，不是「没出现那句错误串」—— 只判错误串的话，
   > report 因为别的原因什么都不输出时也会被判成通过。
   >
   > 读**设备上录的** `perf.data` 那条路仍然**没验过**（手上没有设备录的文件）。

   > 另一处不同，也来自同一个选择：我们这份比官方 host 二进制**多两组子命令**
   > （`api-collect` / `api-prepare` / `boot-record`）。同样是 `__ANDROID__`
   > 成立带来的 —— `command.cpp:213` 无条件注册它们，不编 `cmd_boot_record.cpp`
   > 就链不过。**这不是漏改，是选静态 bionic 的必然结果，PROVENANCE 里要写。**

   > 待验的一处：LLVM 那边 `LLVM_ENABLE_ZSTD=OFF`。NDK sysroot 里的 `.a` 用
   > ZSTD 压过 debug 段（`build-llvm.sh` 开头记过这条教训），所以这不能靠
   > 「判断为无害」——等 simpleperf 能跑了，验收里要真读一个那样的文件，
   > 红了就把 zstd 开起来。
6. ~~**`sqlite3` 的 ICU**~~ —— **做完了（2026-08-29）**，走的是「照官方」那条。

   当天先查后做，两步分开记：

   **查出来的**（当时的判断，事后全部被实际构建证实）：官方那个「带 ICU」是有
   水分的 —— `dist/Android.bp` 里 host 那一支链的是 `libicui18n` `libicuuc`
   **`libicuuc_stubdata`**（桩数据）。官方二进制里 `icudt78_dat` 只有 64 字节，
   包里没有任何 `.dat`。**所以官方那份也是「有接口、没数据」。**
   三条路和代价（原样留着，因为「链真数据」那条还在桌上）：

   | 做法 | 代价 | 得到什么 |
   |---|---|---|
   | **照官方：链 `libicui18n` + `libicuuc` + stubdata** | 取 `external/icu` 并给三个大库写 cmake | 跟官方一样：有 `icu_load_collation`，数据仍要用户自备 |
   | 链**真数据** | 同上，外加二进制涨 28 MB+ | 比官方**好用**，但**跟官方不一样**，得写进 PROVENANCE |
   | 只补 `FTS5`/`RTREE` | 几个编译开关 | 追平**发行版**，同样是「跟官方不一样」 |

   **做出来的**：选了第一条（`cmake/icu.cmake`：`libicuuc` 201 个 .o、
   `libicui18n` 254 个、`libicuuc_stubdata` 1 个；`sqlite3` 开
   `-DSQLITE_ENABLE_ICU`）。两条探针跟官方**逐字一致**，细节见第三节
   `sqlite3` 那段。strip 后 3.29 MB（官方 3.62 MB）。

   **当天被打脸、值得记住的两处**：
   - 「官方那个 ✓ 是从符号大小推的，不算运行时实测」—— 后来补了三条独立证据
     （`readelf -d` 没有 `libicuuc.so`、包里没有 `.dat`、`strings` 里同时有
     `icudt78_dat` 和 `U_FILE_ACCESS_ERROR`），**结论没变，但从「推的」变成了「查的」**。
   - 以为「没数据 = ICU 什么都不灵」。**错**：`upper('äöü')` 照样给 `ÄÖÜ`，
     因为大小写属性编在 `libicuuc` 里（`ucase_props_data.h`），只有排序在 `.dat` 里。

   **剩下那两件：决定不做（2026-08-29，仓库主人拍的板）。**

   | 不做的 | 是什么 | 为什么不做 |
   |---|---|---|
   | ICU **真数据** | 把 `icudt75l.dat`（27,956,384 字节，就在 `submodules/icu/icu4c/source/stubdata/` 里）挂上去，`ucol_open()` 就能成 | 二进制从 3.3 MB 涨到 30 MB+，而**官方没这么做**。做了是「比官方好用」，代价是「跟官方不一样」 |
   | `FTS5` / `RTREE` | 两个编译开关，几乎零成本 | 同样是官方没开。追平的是**发行版**，不是官方 |

   两件都不是「难」，是**方向**问题：这个项目的判据一直是**跟官方 x86_64 那份
   行为一致**，不是「尽量做得好」。谁想反悔得先推翻这条判据，不是加个开关。

   **这个决定有东西盯着，不靠记性**：`tools/build-sqlite3.sh` 的 4/4 拿两条探针
   跟官方逐字比，挂了真数据 `ucol_open()` 就不再报 `U_FILE_ACCESS_ERROR`，当场红。
   （`FTS5`/`RTREE` 没有对应的检查——它们不改这两条探针的结果。要开的话，
   请顺手补一条，别让它悄悄进来。）

7. **`emulator`。查过了，结论是**不做**，三条理由**（2026-08-30 实查）：

   | 查的是什么 | 查出来 |
   |---|---|
   | 官方发了哪些平台 | 当天取 `repository2-3.xml` 数了一遍所有 emulator 的 zip：新命名 `emulator_*` 有 `darwin_aarch64` / `linux_x64` / `windows_x64`，旧命名 `emulator-*` 多一个 `darwin_x64` —— **一个 `linux_aarch64` 都没有**。而 `darwin_aarch64` 在两种命名里都有，所以**又是「有 ARM64 构建，只是不为 Linux 发」**，跟 `skiaparser`、`extras;google;auto` 同一个模式。空白是真的 |
   | 东西是什么 | 不是「一个 qemu」，是 Google 那套封装：AOSP `external/qemu` 这个 **QEMU fork** + AVD 管理 + 快照 + Qt 界面 + 跟 adb/sdkmanager 的集成 |
   | 这台机器跑得动吗 | **跑不动**：`ls /dev/kvm` → 不存在，`systemd-detect-virt` → `kvm`（这台自己就是 KVM 客户机，没开嵌套虚拟化）。没有 KVM，「ARM64 host 跑 ARM64 guest 接近原生」的前提就没了，只能退回 TCG 纯软件模拟，跑手机镜像基本不可用 |

   **① 它当初上单子的理由已经没了。** 它不是「SDK 少个组件」才排进来的，是当**验证
   手段**排进来的——纯 ARM64 Linux 上要验「产物真能在 Android 上跑」，只有真机和
   模拟器两条路（第 1.1 节：这个项目要解决的问题，把验证它的手段也一起挡住了）。
   **2026-08-30 真机那条走通了**：一台 vivo V2337A（Android 16）上
   `tests/hello-native/build.sh --install` 跑出 `20+22=42`，`lldb` 连设备调试也通了
   （见第四节第 2 条）。所以模拟器不再是唯一出路。

   **② 这台机器没有 KVM**，做出来也用不上，得另找裸金属 ARM64。

   **③ 工程量是另一个性质。** 本项目补的是 SDK 里那些命令行工具——一棵源码树 +
   一份 cmake + 一堆 `-D`。移植一个带 Qt 界面、自带构建系统和预编译工具链的
   QEMU fork，不属于同一类工作。

   **真要做的话有三条路，别混为一谈：**

   | 路子 | 是什么 | 代价 |
   |---|---|---|
   | A. 移植 Google 那个 `emulator` | 把 `external/qemu` 编到 linux-aarch64 | 最大。它是本仓库做过的任何一个工具的另一个量级 |
   | B. `qemu-system-aarch64` 直接引导 system image | 自己拼 kernel / ramdisk / super.img，adb 走 TCP | 中等，但**填不上 `emulator` 那个包的坑**——是绕过去不是补上；一样要 KVM 才实用 |
   | C. **Cuttlefish**（AOSP 官方虚拟设备 `device/google/cuttlefish`） | AOSP 自己就发 arm64 host 的包和 `aosp_cf_arm64_phone` 镜像 | **最省力，几乎不用「移植」**，装包 + 下镜像。**要 KVM**（这条没在这台上验过——没 `/dev/kvm` 可验） |

   **什么情况下该翻案**：如果要的是**没有真机的 CI**（别人 clone 了这个仓库、
   手边没 Android 设备），那该做的是 **C**，而且不是「移植」是「装 + 跑」，
   量级是一天不是一个月 —— 前提是那台机器有 KVM。**别去做 A。**

8. **`skiaparser`。查过了，结论是**不做**，理由不是「边缘」而是三条硬的**
   （2026-08-29 实查）：

   | 查的是什么 | 查出来 |
   |---|---|
   | 官方发了哪些平台 | `repository2-3.xml` 里 `skiaparser;3` 的 `host-arch` 明写着 `linux-x64` / `darwin-x64` / **`darwin-aarch64`** / `win-x64` —— **他们有 ARM64 的构建，只是不为 Linux 发** |
   | 东西是什么 | 一个二进制 `skia-grpc-server`（15.9 MB，glibc 动态链，只依赖 libc/libm/libdl/libpthread/librt）。里面是 Skia + gRPC + protobuf 全静态编进去的，构建痕迹是 `bazel-out/k8-opt/…`，服务是 `layoutinspector.proto.SkiaParserService` |
   | 源码在哪 | **没找到公开的。** 查过 `tools/base/dynamic-layout-inspector`（只有 agent 和 common，`/skia` 是 404）、`tools/adt/idea/layout-inspector`（只有 Kotlin/Java 那一侧）、`external/skia`（没有相关 target）；`tools/vendor/google` 不公开 |

   **但真正决定不做的是第四条**：**skiaparser 的唯一消费者是 Android Studio 的
   Layout Inspector，而 Android Studio 没有官方的 Linux ARM64 版**
   （[官方下载页只列 x86_64](https://developer.android.com/studio)，社区那些
   aarch64 包是打补丁 + 用 qemu-user 跑部分原生工具凑出来的）。
   **给一个在这个平台上不存在的消费者移植它的辅助程序，没有意义。**

   > 反过来说值得记一句：社区那套「patched Studio on ARM64 Linux」正是靠
   > **qemu-user 跑那些原生工具**撑着的 —— 而本仓库这套 SDK/NDK 已经把其中
   > 绝大部分换成了原生件。真有人走那条路，剩下要 qemu 的就只有 Layout
   > Inspector 这一处了。

9. **`extras;google;auto`（Android Auto 的 Desktop Head Unit）。查过了：
   这是第一条「缺口是真的，但我们编不了」。**（2026-08-29）

   | 查的是什么 | 查出来 |
   |---|---|
   | 官方发了哪些平台 | `host-arch` = **`darwin-aarch64`** / `darwin-x64` / `linux-x64` / `win-x64` —— **又是 macOS 有 ARM64、Linux 没有**，跟 `skiaparser` 一模一样 |
   | 东西是什么 | `desktop-head-unit`，6.7 MB，**动态链**：`libasound`（ALSA）、`libusb-1.0`、`libc++` / `libc++abi`、`libgcc_s` + 标准 libc。另带一份 `libusb-1.0.so.0` 和一堆 `config/*.ini` |
   | 源码 | **闭源。** 它不是 AOSP 的东西，Google 只发二进制，[官方文档](https://developer.android.com/training/cars/testing/dhu)里也只给下载 |
   | 消费者在不在 | **在。** DHU 是独立命令行工具，不依赖 Android Studio —— 任何在 ARM64 Linux 上开发 Android Auto 应用的人都要它。**这一点跟 `skiaparser` 正相反** |

   所以这条**不是「不值得做」，是「做不了」**：没有源码，编无可编。

   > **顺带一条能省事的观察：连 qemu 那条退路都比 `hermesc` 那次难走。**
   > 官方 `hermesc` 是**静态**的 x86_64 ELF，装个 `qemu-user-static` 就能跑
   > （今天实测：静态的退出码 0、动态的 255，因为 qemu-user 找不到 x86_64 的
   > guest 库）。而 DHU 是**动态**链的，要跑就得整套 x86_64 的
   > `libasound` / `libusb` / `libc++` —— 那是一整个 x86_64 sysroot 的事。
   >
   > 想在 ARM64 Linux 上做 Android Auto 开发，现实的路是社区的开源替代
   > （如 [OpenHU](https://github.com/iConsole/OpenHU)）或者换台机器。

10. RenderScript 那 9 个：**决定不做**（Android 12 起废弃）。

---

## 五、验证纪律（这一节比技术方案重要）

这个项目有一个**结构性陷阱**：绝大多数贡献者会在 x86 机器上开发，产物却要在 ARM 上跑。而交叉编译最典型的失败模式，是**在开发机上一切正常、到目标机上才炸**——因为两边拿到的根本不是同一份东西（不同的编译器、不同的库、不同的可达资源）。

所以规矩：

1. **在 x86 上「编过了」什么都不证明。** 产物必须在真 ARM64 机器上跑过才算数。

   > 反过来还有一条，2026-08-29 实测的：**验收机上别装 `qemu-user-static`。**
   > binfmt 一注册，x86_64 的二进制在 ARM64 上就「跑得起来」，而本仓库多条检查
   > 的判据正是「真跑一次，看退出码」。同一个静态链接的 x86_64 二进制：
   > 装着 qemu 退出码 **0**（判成能跑，假绿），卸掉后 **126**（判红，对）。
   > 动态链接的那种两种环境都判红（qemu 找不到 guest 库，报 255）——
   > **所以危险的恰好是静态二进制，而本仓库自己的产物全是静态的。**
   > 需要跑官方 x86_64 工具做对照时（比如 `build-hermesc.sh` 的第四步）才装，
   > 用完卸掉；脚本在没有它时会明说「这一条没验过」。
2. **每个产物都要有能跑的验收命令**，不是「文件存在」。
   `aapt2 version` 只是起点；真正的验收是 `aapt2 compile` 一个真资源、`clang` 真编出一个 `.so`。
3. **验收必须能一键跑。** 见下面的 `tests/`。任何人拿一台 ARM64 机器都应该能在一条命令内知道好没好。
4. **最终验收是端到端的**：样例工程出 APK，而不是「工具链看起来编好了」。
5. **每加一个工具，就加一条能在它坏掉时失败的测试。** 写完先把修复摘掉跑一遍，确认它真的会红——**不会红的测试没有价值**。
6. **「和官方行为一致」可以变成可检查的，别只当口号。** 办法：在一台 x86_64 机器上，
   拿 Google 官方的产物跑一个**确定的**输入，把结果（字节串或哈希）记进测试；
   ARM64 上编出来的那个必须吐出同样的东西。`tools/build-hprof-conv.sh` 和
   `tools/build-etc1tool.sh` 的最后一条就是这么写的——**第四节那句「产物必须和官方
   x86_64 版行为一致」到此第一次有了检查手段**，而不是只写在文档里。
   （做得到的前提是那个工具的输出确定：同样输入永远同样输出。带时间戳、
   带随机数、带并发顺序的输出就不行，那种得另想办法。`mke2fs` 是靠
   `-U` 固定 UUID、`-E hash_seed=` 固定哈希种子、`E2FSPROGS_FAKE_TIME` 假时间
   三样一起才变确定的。）

   **比对要允许「必然不同」的字段——但必须逐个说清是哪几个、为什么。**
   实际撞到的是**两类**，别混为一谈：

   | | 例子 | 根源 | 换台机器还会不会有 |
   |---|---|---|---|
   | **架构** | `mke2fs` 的 `s_flags`：官方 1（SIGNED_HASH），我们 2（UNSIGNED） | x86 的 `char` 有符号、aarch64 无符号，ext4 **有意**把这一位记进超级块，因为目录哈希依赖它 | 会，永远 |
   | **libc** | `make_f2fs` 的 `checkpoint_ver`：官方 `0x6b8b4567`，我们 `0x7abd20a3` | `f2fs_format.c:741` 是 `srand(0); rand()｜1`。同一个种子，**glibc 和 bionic 的 `rand()` 出来的数不一样**。跟 x86/ARM 无关 | 会，跟着产物走 |
   | **运行环境** | `make_f2fs` 的 `sb->version`：这台是 `6.18.44-fc-v22`，那台是 `6.17.0-1020-oracle` | `f2fs_format.c:590-598` 把**跑 mkfs 那台机器的内核版本串**写进超级块 | 会，而且**换机器、升内核都会变** |

   三类都是把差异**清零后再比**，剩下逐字节相同。**「归一化掉几个字段再比」可以，
   「哈希对不上就把这条测试删了」不可以**；清掉的每个字段都要能说出是上面哪一类。

   两条从实战里换来的补充：

   - **能用参数固定的就用参数，别都推给归一化。** `make_f2fs` 的根 inode uid/gid
     默认是 `getuid()/getgid()`（`lib/libf2fs.c:727` —— 尽管 `-R` 的用法里写着
     「default: 0:0」），加个 `-R 0:0` 就固定了，不必归一化。
   - **第三类「运行环境」是只有换台机器才照得出来的。** `make_f2fs` 的第一版黄金值
     是在这个 x86 容器里算的，把容器的内核版本串和 `root` 的 uid 一起烤了进去——
     在这台机器上永远绿，**一到真 ARM64 机器上就红**。
     **测试写得过死也是一种错，而且是本地怎么跑都发现不了的那种。**

### `tests/` 里该有什么

两个样例工程，覆盖两条不同的路径：

| 工程 | 验的是 | 为什么必须分开 |
|---|---|---|
| `tests/hello-jvm/` | 纯 Java 的 app | 走 `aapt2` + `d8` + `zipalign` + `apksigner`，**不碰 NDK**。**已经有了**——重点是 `aapt2 link` 生成 `R.java` 那一段，`hello-native` 完全没走到 |
| `tests/hello-native/` | 带原生库的 app | 唯一能验证 **NDK host 工具链**真的能编 C 的路径。**已经有了**——`tests/hello-native/build.sh` 一条命令走完 ndk-build → javac → d8 → aapt2 → zipalign → apksigner，`--install` 还会核对原生函数的返回值 |

M1 的验收就是这两个工程都能在 ARM64 上 `./gradlew assembleRelease` 出 APK，并且 `aapt2 dump badging` 能读出正确的包名。

**2026-08-29 达到了**，一条命令重跑：

```bash
tests/gradle-build.sh          # 两个工程一起，末尾逐项拆 APK 验
```

实测（Gradle 9.7.1 + AGP 9.3.2 + JDK 21，SDK/NDK 都是从**发布包解出来的**，
不是机器上装的那套）：

| 工程 | APK | 验到什么 |
|---|---|---|
| `hello-jvm` | 643 990 字节 | 包名 `com.example.hellojvm`，`AndroidManifest.xml` / `resources.arsc` / `classes.dex` 都在 |
| `hello-native` | 644 230 字节 | 同上，外加 `lib/arm64-v8a/libhellonative.so` 是 ARM aarch64、里面有 `Java_com_example_hellonative_*` 符号 |

**在此之前只验过手工流水线**（`build.sh` 直接调 `javac`/`d8`/`aapt2`）。手工那条
全绿推不出这条能过 —— AGP 自己解析 maven 上的 aapt2、自己找 cmake、自己调
`llvm-strip`，走的是完全不同的三条路径。第一次跑就撞出四个坎，两个是我们自己
包里的缺陷（第三节）。

> **`tests/` 下两条路共用同一份源码**：`build.sh` 走手工流水线、产物在 `build/`；
> `./gradlew` 走 AGP、产物在 `build-gradle/`。清单只有 `AndroidManifest.xml` 一份，
> AGP 要的那份（去掉 `package=` 属性）在配置阶段从它生成 —— 两份手工同步的清单
> 早晚会对不上。

加分项：ARM64 模拟器（`system-images;android-*;google_apis;arm64-v8a`）上真的装起来跑一次。

> ⚠️ **但模拟器本身在 ARM64 Linux 上也没有。** 查 Google 的 manifest：
> `emulator` 包只发 `linux/x64`、`macosx/aarch64`、`windows/x64`（旧版号里还有
> `macosx/x64`）——**没有 `linux/aarch64`**。（2026-08-30 复核过一遍：结论没变，
> 但当时漏了 Windows，`macosx/x64` 也只在旧命名那批里还有。）
> 跟 1.1 节是同一个模式：这个项目要解决的问题，把验证这个项目的手段也一起挡住了。
>
> 所以「产物真的能在 Android 上跑」这一步，在纯 ARM64 Linux 环境里只剩两条路：
>
> 1. **接一台真机走 adb** —— **2026-08-30 走通了**：一台 vivo V2337A（Android 16）
>    隔着 ssh 反向隧道接进来，`tests/hello-native/build.sh --install` 装上并跑出
>    `RESULT native ok: 64-bit … 20+22=42`，`tools/verify-lldb-device.sh` 也把
>    连设备调试验掉了。（写这段时这里还是「只验了 version，连设备那条路还没碰」。）
> 2. **`qemu-system-aarch64` 直接引导 system image**，绕开 Google 的模拟器封装。
>
> 在 ARM64 host 上跑 ARM64 guest 接近原生速度，性能不是问题；缺的是 Google 那层封装。
> 这本身也可以是这个项目的一个产出。

---

## 六、从哪开始

前提是**一台 aarch64 机器**（第七节）。在 x86 上你可以读代码、改文档、写补丁，
但别报「编过了」——第五节第 1 条。

### 6.1 接手的第一件事

```bash
tools/setup-hooks.sh          # 改之前 pull、改完自动推送，靠钩子机械执行
```

理由、绕过办法、以及为什么 git 不允许 clone 时自动装钩子，都在
[docs/LESSONS.md](LESSONS.md)。**没跑这一步，那两条规矩就只能靠自觉。**

### 6.2 先复现事实，别信这份 README

```bash
tools/verify-claims.sh              # 自动找 $ANDROID_HOME 底下的 NDK
tools/verify-claims.sh /path/to/ndk
```

退出码 10 表示 Google 已经发 linux/aarch64 包了——那这个项目可以关掉，是好事。

### 6.3 再把已经铺好的那段路自己走一遍

**这一段不是让你开发，是让你确认这些结论在你这台机器上也成立。**
每一条都在一台 aarch64 Ubuntu 云实例上跑通过（第四节「现在到哪了」），
但那是**一台**机器——你这台是第二个数据点。

```bash
tools/patch-ndk.sh                     # 1. 让 NDK 认得 linux-aarch64
tools/patch-ndk.sh --check             #    验：五个补丁都在（四个 host tag +
                                       #    一个把静默降级改成报错的）

tools/make-shim-toolchain.sh           # 2. 薄壳 host 工具链（不编 LLVM，很快）
                                       #    想要真的那份：tools/build-llvm.sh，
                                       #    几小时 + 24G 磁盘，见第四节末尾

tools/build-aapt2.sh                   # 3. 自己编 aapt2（几十分钟，要 12G 磁盘）
                                       #    产物在 work/out/aapt2

tools/build-zipalign.sh                # 4. 自己编 zipalign（复用上一步的源码树，
                                       #    只多取 2.5 MB，几分钟）
                                       #    产物在 work/out/zipalign

# 5. 端到端
export AAPT2=$PWD/work/out/aapt2
export ZIPALIGN=$PWD/work/out/zipalign
tests/hello-jvm/build.sh    --install
tests/hello-native/build.sh --install

tools/make-dist.sh --check             # 6. 想要一个能解压到 $ANDROID_HOME 的包：
                                       #    先看差什么（不写文件）。要真出包得先把
                                       #    13 个工具都编出来，见第四节 M4
```

| 步 | 跑通了说明什么 | 出问题看哪 |
|---|---|---|
| 1 | NDK 那四处写死的 host tag 都补上了，外加把 `HOST_PYTHON` 的静默降级改成报错 | 第二节、`patches/ndk/README.md` |
| 2 | 系统 clang 补上三个内建默认值就能当 NDK 的 host 工具链使 | 第四节「一条不用编 LLVM 的快速通道」 |
| 3 | aapt2 这块砖是自己的了——三个链接错误的根因逐个记在脚本注释里 | `tools/build-aapt2.sh` 开头 |
| 4 | zipalign 也是自己的了。`--verify` 的四条测试里，**第一条是测试自身的有效性自检**：先要求一个刻意造歪的 zip 被 `-c` 判失败 | `cmake/zipalign.cmake` |
| 5 | 资源链和 NDK 编 C 两条路都通到真机 | `tests/*/README.md` |

`--install` 要有真设备。云机器没 USB，走 ssh 反向隧道**顺序很要紧**，
坑写在 `tests/common.sh` 的报错里了。去掉 `--install` 就只编不装——
也验到了东西，但记住第五节第 4 条：**最终验收是端到端的**，编出 APK 不等于跑得起来。

> 第 4 步在一台 aarch64 Ubuntu 上一次过。**但那还是同一台机器**——换个发行版、
> 换个 clang 版本就未必。你这台要是不一样，那结果比「又成了一次」值钱得多，
> 报成 issue（第九节）。
>
> 真编不出来也别急着用 `ZIPALIGN=/path/to/别人的/zipalign` 绕过去接着跑第 5 步——
> **卡在哪本身才是这一步最有价值的产出。**

**这一节以前写的是另一条路**——「clone `ReVanced/aapt2`，去掉 toolchain file，
在 ARM64 Linux 上原生编成 glibc 二进制，再逐个啃 bionic → glibc 的差异」。
那条路没走，也不用走：第三节验过**静态 bionic 二进制在 glibc ARM64 Linux 上直接能跑**，
所以 `tools/build-aapt2.sh` 保留了上游的 Android 目标，一个差异都没啃。
留这段是因为方向选择本身是个结论：**先验「要不要啃」，再决定啃不啃**——
省下的是一整条路的工作量。

### 6.4 然后从这三个缺口里挑一个

「第一个真正的胜利」已经拿到了：两个样例工程都在真机上出了 APK 并且跑起来，
资源渲染对、JNI 算对。**剩下的是把路上别人的砖换成自己的。** 按上手难度排：

| 缺口 | 从哪下手 |
|---|---|
| **M3 只剩 `adb`** | 另外六个都做完了。`adb` 是另一个量级（十几个新目标 + 三处代码生成 + 一个 Java 子构建），实查结果写在 M3 那节，动手前先读。它也是唯一「不做也不太卡」的——发行版有 arm64 包。 |
| ~~**M3：只剩 `adb`**~~ | **`adb` 也编出来了** —— `tools/build-adb.sh` + `cmake/adb.cmake` + `cmake/adb-deps.cmake` + `tools/gen-deployagent.sh`（唯一一处 Java 子构建）。真机上五步全绿。**`platform-tools` 八个 ELF 全是自己的了。** |
| ~~**M4：做成能装的东西**~~ | **做出来了，真机上出过包** —— `tools/make-dist.sh`，55 MB 的 tar.gz，14 个自己编的 host 二进制 + 官方包里跟架构无关的那部分，带 `PROVENANCE.txt` 逐文件说明出处。出包前四条硬指标：host 位置的 ELF 全是 aarch64、**它们真的能跑**（逐个执行，退出码 < 126）、`mke2fs.conf` 在、两个 `NOTICE.txt` 都在。**真缺口 0 个**（`adb` 编出来之后）；另外 9 个是 RenderScript 及其连带，不打算做。**NDK 也打了包**——`tools/make-ndk-dist.sh`，位置判据跟 SDK 不是同一条（NDK 的目标产物在三元组目录下，不是 ABI 目录），名单在官方原版 NDK 上校准过：host 位置 133 个 ELF 全中、漏在名单外的 0 个。八道检查全做了变异测试，**端到端验过**：tar.gz 解压到全新位置，编出 APK 装真机跑通，且不传 `NDK_HOST_PYTHON`——包里的 python3 自足是证出来的。见第四节 M4。 |
| ~~**host 工具链是薄壳，不是编出来的**~~ | **编出来了** —— `tools/build-llvm.sh`，源码 pin 在 NDK 自己报的那个 commit（`d8003a45`，分支 `llvm-r522817`），cmake flags 抄 Google 的 `toolchain/llvm_android`。真 ARM64 机器上 `--verify` 六步全绿。`python3/` 也自己编了（`tools/build-python.sh`），真机上验过自足。剩下的小尾巴只有 `clang-tidy` / `clangd` / `lldb` / `llvm-bolt` 没编。 |

这两个都不碰也有一件有价值的事：**在没试过的 ARM64 硬件上把 6.2、6.3 跑一遍，
把结果报成 issue——成功也要报**（第九节）。目前所有结论都出自同一台机器，
第二个数据点比第一个便宜，价值不比它低。

---

## 七、开发环境要求

| | 最低 | 舒服 |
|---|---|---|
| 架构 | aarch64（`uname -m`） | 同左 |
| 磁盘 | 40 GB | 80 GB+ |
| 内存 | 8 GB | 16 GB+ |
| 核数 | 2 | 4+ |

**内存是最容易踩的坑**：LLVM 的链接阶段极吃内存，8 GB 以下大概率 OOM。压住链接并发：

```bash
cmake -G Ninja -DLLVM_PARALLEL_LINK_JOBS=1 -DLLVM_USE_LINKER=lld ...
```

**一台 x86_64 对照机很有用**（不是必需）：ARM 产物出问题时，第一个要回答的问题永远是「x86 上一样吗」。这一问能省掉大量瞎猜。

### 开发环境 ≠ 下游的使用环境

**这两个必须分开，混在一起的后果不是「乱」，是验证会失真。** 开发环境里随手
放着的一个 x86_64 工具、一个 qemu，都会让「在干净机器上能不能用」这个问题
得到假答案 —— 第五节第 1 条那条 qemu 的教训就是这么来的。

| | 开发环境（做这个项目） | 下游使用环境（用这个项目） |
|---|---|---|
| 是什么 | 本仓库 + `WORK`（源码树、构建树、产物） | 一个干净的 `$ANDROID_HOME` |
| 里面有 | 18+ 棵源码树、几 GB 构建树、**官方 x86_64 NDK（当输入）**、对照用的官方 x86_64 二进制 | **只有 release 解出来的东西** + Google 那半 |
| 允许有 x86_64 的东西吗 | 允许，而且必须有（对照和输入都要） | **一个都不该有** |
| qemu | **别装**（会让「真跑一次」那类检查假绿）。要做官方对照时临时装、用完卸 | 不需要 |
| 怎么来的 | `git clone` + `tools/build-*.sh` | `tools/make-downstream-sdk.sh` |

**下游那个 `$ANDROID_HOME` 里到底要有什么**（2026-08-29 实测，不是推的）：

| 谁给的 | 什么 | 怎么来 |
|---|---|---|
| **我们** | `build-tools/` `platform-tools/` `ndk/` | 两个 release tar.gz 解开 |
| Google，跟架构无关 | `licenses/` | `sdkmanager --licenses`，或从别的 SDK 拷 |
| Google，跟架构无关 | `platforms/android-XX/` | **licenses 就位后 AGP 自己会下**（实测：只解我们两个包会报 `platforms;android-36` 装不了；补上 licenses 之后它自己装完，端到端全绿） |

一条命令铺好并当场验（每个原生件**真执行一次**，不是看文件名）：

```bash
tools/make-downstream-sdk.sh [目标目录]      # 默认 $HOME/Android/Sdk
```

> **`cmake.dir` 现在可以不写了**（2026-08-29 实测）：**AGP 按目录名挑 cmake，
> 不按二进制自报的版本号挑。** 把系统的 3.28.3 摆成 `cmake/3.22.1/`
> （AGP 当前的默认号），`local.properties` 里只写 `sdk.dir`，构建照样过 ——
> CMakeCache 里留下的是
> `CMAKE_MAKE_PROGRAM = <SDK>/cmake/3.22.1/bin/ninja` 而
> `CMAKE_CACHE_MINOR_VERSION = 28`：它从「3.22.1」那个目录取了 ninja，
> 真正跑的是 3.28。
>
> `tools/link-system-tools.sh` 因此会多建一个**目录软链** `cmake/3.22.1 -> 3.28.3`
> ——用软链不用拷贝，`ls -l` 一眼看得出它是别名，不装成真的。
> 已存在（比如 AGP 自己下的那份 x86_64）时不覆盖，只报告。
>
> **这件事记在三个地方，缺一不可：**
>
> | 记在哪 | 给谁看 |
> |---|---|
> | **`$SDK/PROVENANCE-system-tools.txt`**（脚本自己写的） | **将来站在 `cmake/3.22.1/` 里敲 `cmake --version` 看到 3.28.3 的那个人。** 他不会来翻这份 README —— 记录得放在他正站着的地方 |
> | 本节 + [docs/INSTALL.md](INSTALL.md) 第三节 | 装之前先读文档的人 |
> | 脚本运行时的输出 | 正在跑它的人 |
>
> 那份自述里写清楚了：哪些软链、指向哪、别名为什么不是笔误、怎么撤掉
> （撤销命令实测过：只删走指向 `/usr` 的那批，包自带的软链一个不动），
> 以及换台机器要重跑而不是拷贝。

**还有两样在 SDK 之外，包里没有也不该有**，下游在自己工程里配：
`android.aapt2FromMavenOverride=<SDK>/build-tools/*/aapt2`、
以及 React Native 工程要的 `hermesc`（`tools/build-hermesc.sh` 编，
`react { hermesCommand }` 指过去）。理由都在
[docs/INSTALL.md](INSTALL.md) 第三节。

---

## 八、许可证

本仓库自身的构建脚本按 **Apache 2.0** 授权。

构建出来的产物沿用各自上游的许可证：AOSP 组件为 Apache 2.0，LLVM 为 Apache 2.0 with LLVM Exception。**分发二进制时必须一并带上上游的 NOTICE / LICENSE 文件。**

本项目与 Google 无关，不隶属于 Android 开源项目。

---

## 八点五、CI

**开源当天第一件事**：公共仓库有免费的 ARM64 runner（`ubuntu-24.04-arm`），
把验收挂上去，每次 push 自己证明自己 —— 这比任何文档都更能支撑
「用户能在 ARM Linux 上做 x86 上能做的事」这句话。

| workflow | 什么时候跑 | 干什么 |
|---|---|---|
| `checks.yml` | 每次 push / PR | 跑 `tools/ci-checks.sh`：shell 语法、CRLF、可执行位、`PARITY.md ↔ parity.json`、README 相对链接、`verify-claims.sh`（项目前提还成不成立） |
| `smoke-build.yml` | 手动 + 每月 | **真编一个工具出来**：官方 NDK → `make-shim-toolchain.sh` 自举 → 编 `hprof-conv` → 跑它的验收（跟官方产物逐字节比） |

**为什么要有第二个**：第一个全是静态检查，**一行代码都没编译过**。
「脚本语法对」不等于「编得出东西」—— 这个仓库栽过同形的跟头（`build-adb.sh`
六步全绿，而那份 `adb` 根本起不了服务器）。

**逻辑放在 `tools/ci-checks.sh` 里，YAML 只当薄壳** —— 那个脚本在本机就能跑、
能验、能做变异测试，不是一份推上去才知道对不对的配置。实测过：故意加一个指空的
链接、故意塞一个语法错，两次都红。

### CI 覆盖不到的，别假装它能

| 覆盖不到 | 为什么 | 怎么办 |
|---|---|---|
| 连设备的那些（装 APK、`lldb` 连设备、读设备录的 `perf.data`） | 托管 runner 没有 USB，也接不到手机 | 自托管 runner，或手动跑。**那些脚本没设备时退出码是 2（没条件验）不是 1** —— CI 里要把 2 当「跳过」，当失败会让「没测」冒充「测挂了」 |
| 模拟器 / Cuttlefish | 要 KVM，托管 runner 给不了 | 见路线图第 7 条：决定不做 |
| 整条工具链的完整构建（LLVM 88 分钟） | 太重，不该每次 push 跑 | 发版前手动走 Release 清单第 0 步 |

> ⚠️ **这两份 workflow 还没在 CI 上真跑过** —— 仓库还是私有的，没开 Actions。
> `tools/ci-checks.sh` 的**内容**在本机验过（含变异测试），但 YAML 的接线没有。
> 开源后第一件事就是看它们绿不绿，别默认它们是对的。

## 九、参与

最有价值的贡献，按顺序：

1. **在没试过的 ARM64 硬件上跑验收**，把结果报成 issue（成功也要报）。
2. **NDK 的 host 工具链**——最大的未解块。
3. **构建的可复现性**：同样的输入应该编出同样的产物。

具体从哪块下手、每块从哪读起，见 [6.4](#64-然后从这三个缺口里挑一个)。
