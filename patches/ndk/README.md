# NDK 补丁

打在**已安装的 NDK**上，让它认得 `linux-aarch64` 这个 host tag。

```bash
tools/patch-ndk.sh            # 打
tools/patch-ndk.sh --check    # 只看状态
tools/patch-ndk.sh --revert   # 撤销
tools/verify-claims.sh        # 验：三处 BLOCK 应该都变 PASS
```

## 这些补丁做什么，不做什么

**做**：让 NDK 在 aarch64 host 上算出 `linux-aarch64`，然后去
`toolchains/llvm/prebuilt/linux-aarch64/` 找工具链。

**不做**：产出那个目录底下的东西。那是 M1 的活。

所以打完补丁在 ARM64 机器上编东西，会得到一条清楚的「找不到工具链」——
而不是打补丁前那条 `ERROR: Unknown host CPU architecture: aarch64`。
从「不知道你在说什么」变成「知道你要什么，但我没有」。这就是这几个补丁的全部价值。

真机上打完四个补丁，`ndk-build` 编一个 .c 文件的实际输出：

```
make: .../toolchains/llvm/prebuilt/linux-aarch64/bin/clang: No such file or directory
make: *** [...] Error 127
```

**`0005` 补的不是 host tag，是另一件事**，见本文末尾「`0005`：把静默降级改成报错」。

NDK 里一共有**四条**求 host tag 的路径，四条都要改（`0001`–`0004`）：

| | 补丁 | 改了什么 | 不改的话 |
|---|---|---|---|
| `ndk-build`（辅助程序） | `0001` | `build/tools/ndk_bin_common.sh` | 报 `Unknown host CPU architecture: aarch64`，exit 1 |
| CMake | `0002` | `build/cmake/android.toolchain.cmake` 和 `android-legacy.toolchain.cmake` | 静悄悄用 `linux-x86_64` |
| standalone toolchain | `0003` | `build/tools/make_standalone_toolchain.py` | 静悄悄用 `linux-x86_64`，然后报「找不到工具链」 |
| **`ndk-build`（真编东西那条）** | `0004` | `build/core/init.mk` | 去 exec x86_64 的 clang，报 `Syntax error: "(" unexpected` |

**`0001` 和 `0004` 是两条独立的路径，别以为改了一个就够。** `ndk_bin_common.sh`
只管找 python / make；决定用哪个 clang 的是 `init.mk` 里的 `HOST_TAG64`。
只打 0001 的话，`ndk-build --version` 会正常打印 GNU Make 的版本让你以为成了，
一编东西就露馅。

`0004` 是**在真 ARM64 机器上撞出来的**，不是读代码找到的：`verify-claims.sh`
当时 grep 的是字面量 `linux-x86_64`，而 init.mk 里是 `$(HOST_OS_BASE)-$(HOST_ARCH64)`
拼出来的，抓不到。现在加了针对性检查。

`0003` 那个工具**从 NDK r19 起就废弃了**，也不在 M1 路径上（Gradle / CMake /
ndk-build 都不走它）。补它只是为了不留一处会返回错 tag 的地方。

**0002 必须改两个文件。** `android.toolchain.cmake` 开头默认就 `include` 了 legacy
那份然后 `return()`，除非显式传 `-DANDROID_USE_LEGACY_TOOLCHAIN_FILE=OFF`。
只改前者等于没改——README 第二节原来只指了前者，是不够的。

## 为什么是 `linux-aarch64` 而不是 `linux-arm64`

没有上游先例可依。上游 NDK 的 [`ndk/hosts.py`](https://android.googlesource.com/platform/ndk/+/refs/heads/master/ndk/hosts.py)
里 `Host` 枚举只有 `Darwin` / `Linux` / `Windows64`，`host_to_tag()` 无条件拼
`-x86_64`——**连 macOS ARM 都没有自己的 tag**，靠的是在 `darwin-x86_64` 目录里
放 universal 二进制蒙混过去。

选 `aarch64` 的两个理由：

1. 它就是 `uname -m` 在 ARM64 Linux 上的原样输出，映射不用查表。
2. 跟 sdkmanager manifest 里 `<host-arch>aarch64</host-arch>` 的用词一致——
   M4 要出能被 sdkmanager 认的 repository XML，那时会用到同一个词。

`0001` 里额外把 `linux-arm64` 归一到 `linux-aarch64`（个别 Linux 系统的
`uname -m` 报 `arm64`），免得出现两个只有名字不同的 prebuilt 目录。

## NDK 升级后补丁打不上了怎么办

`tools/patch-ndk.sh` 会报「对不上」并退出，不会硬打。**别用 `--force` 之类的招**：
toolchain 文件打歪了，症状是几百行之后某个不相干的变量为空，很难查。

rebase 的做法：

```bash
# 1. 拿两份新版 NDK 的原文件
cp $NDK/build/tools/ndk_bin_common.sh /tmp/orig/
# 2. 照着旧补丁手工改一遍新文件
# 3. 重新生成
diff -u --label a/build/tools/ndk_bin_common.sh --label b/build/tools/ndk_bin_common.sh \
    /tmp/orig/ndk_bin_common.sh /tmp/new/ndk_bin_common.sh
# 4. 验
tools/patch-ndk.sh --check && tools/verify-claims.sh
```

补丁头部的说明不要丢——那里记着**为什么**这么改，比 diff 本身值钱。

## 验过什么

补丁不是「看着对」，是在 r27.1 的真文件上跑出来的：

| 验的 | 结果 |
|---|---|
| `打 → verify-claims` | 三处 BLOCK 全变 PASS |
| `再打一次` | 幂等，报「已打」 |
| `撤销 → 跟原文件比` | 逐字节一致 |
| 上下文改坏后 `--check` | 报「对不上」并退出 1，不硬打 |
| CMake 块实际选出的 tag | Linux/aarch64 和 Linux/arm64 → `linux-aarch64`；Linux/x86_64、Darwin、Windows 不变 |
| `ndk_bin_common.sh` 实际算出的 tag | 同上；未知架构（如 ppc64le）照样报错退出 |
| `get_host_tag_or_die()` 实际返回值（用 ast 把函数抠出来，注入假的 sys / platform 跑） | linux+aarch64、linux+arm64 → `linux-aarch64`；linux+x86_64、darwin、win32 不变；freebsd 照样退出。**未打补丁的同一个函数：linux+aarch64 → `linux-x86_64`** |
| 打补丁前的 Linux/aarch64 | `ERROR: Unknown host CPU architecture: aarch64`，exit 1 |
| 打完补丁的 .py | `py_compile` 通过 |
| `init.mk` 算出的 `HOST_TAG64`（抠出真代码，用 NDK 自带的 make 跑，只把 uname 调用换成桩） | linux+aarch64、linux+arm64 → `linux-aarch64`；linux+x86_64、windows 不变；**darwin+arm64 仍是 `darwin-x86_64`**（macOS 的 universal 二进制不能误伤）。**未打补丁的：linux+aarch64 → `linux-x86_64`** |

`CMAKE_HOST_SYSTEM_PROCESSOR` 在 toolchain file 里能不能拿到，是单独验过的：
CMake 3.22.1（Android Studio 默认）和 4.3 都可以。低于 3.22 没测。

**这些都是在 x86 上验的**——按第五节第 1 条，它只证明逻辑对，不证明在 ARM64 机器上
真能跑。真机验收是 M1 的事。


## `0005`：把静默降级改成报错

**这一个跟 host tag 无关**，也不是 aarch64 特有的，任何缺自带 `python3/` 的 NDK
都会踩。放在这儿是因为它改的是同一个文件（`build/core/init.mk`），而且
`tools/build-llvm.sh` 编出来的那份工具链**正好没有** `python3/`（只软链了系统的）。

上游原文：

```make
ifndef HOST_PYTHON
    HOST_PYTHON := python
endif
```

Ubuntu 22.04 以后没有 `python` 这个名字。而 `HOST_PYTHON` 的每一处用法都是
`$(shell …)`——**命令不存在时 `$(shell)` 返回空串，不报错、不中断**。

后果不是「编不出来」，是**「编出来的不对，而且报成功」**。实测（x86_64 容器，
把工具链里的 `python3/` 挪走、`PATH` 里也没有 python，编一个要
`-fsanitize=address` 的模块）：

| | 退出码 | `libs/arm64-v8a/` 里有什么 |
|---|---|---|
| 有 `python3` | 0 | `libclang_rt.asan-aarch64-android.so`、`libhello.so`、`wrap.sh` |
| 没有、**上游原状** | **0** | 只有 `libhello.so` |
| 没有、打了 `0005` | 2 | `init.mk:330: *** No Python interpreter found. … Stop.` |

第二行就是这个补丁存在的理由：要了 ASan，**运行时库和 `wrap.sh` 都没进去**，
装到设备上会因为缺库起不来——而 `ndk-build` 报的是成功。
受影响的还有 `APP_PLATFORM`（`setup-app-platform.mk`）和 `APP_DEBUGGABLE`
（`add-application.mk`），都是悄悄取默认值。
其中 `sanitizers.mk` 那条是 `setup-toolchain.mk` **无条件 include** 的，
也就是说每次 `ndk-build` 都会跑一次 python。

改法：先试 `python3`，再试 `python`，两个都没有就 `$(error)`。

**这会改变行为**：今天在一台既没 `python3` 也没 `python` 的机器上，`ndk-build`
是「成功」的；打完补丁它会失败。这正是想要的——**一次响亮的失败胜过一堆
不知道哪里不对的产物**。装了 `python3` 的机器（也就是绝大多数）一点不受影响。

那五个脚本（`ldflags_to_sanitizers.py` `extract_platform.py` `extract_manifest.py`
`gen_compile_db.py` `dump_compile_commands.py`）全是标准库，`shlex.join` 要求
Python >= 3.8——**所以系统的 python3 就够用，不必是 NDK 自带那份 CPython**。
