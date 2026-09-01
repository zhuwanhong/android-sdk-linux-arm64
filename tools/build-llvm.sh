#!/usr/bin/env bash
# 编 host 工具链本身：toolchains/llvm/prebuilt/linux-<arch>/ 那一整块。
#
# 跟这个仓库里别的 build-*.sh **不是一类东西**，所以没有 source build-common.sh：
# 那些工具是拿 NDK 交叉编出 arm64-v8a 的 **目标** 二进制，骨架里那套
# （android.toolchain.cmake、ANDROID_ABI、验收时断言产物是 aarch64）在这里全不适用。
# 这里编的是**跑在本机上的 host 二进制**，本机是什么架构就编出什么架构。
# 只有 die/step/ok 这几个打印函数是照抄的，为的是输出长得一样。
#
#   tools/build-llvm.sh --fetch    取源码（2.1 GB）
#   tools/build-llvm.sh --build    编 + 装（久，见下面的实测）
#   tools/build-llvm.sh --verify   验
#
# ---------------------------------------------------------------------------
# 源码取哪一份：**问 NDK 自己的 clang 要**，不猜。
#
#   $ .../linux-x86_64/bin/clang --version
#   Android (12285214, +pgo, +bolt, +lto, +mlgo, based on r522817b) clang version 18.0.2
#   (https://android.googlesource.com/toolchain/llvm-project d8003a456d14a3deb8054cdaa529ffbf02d9b262)
#
# 括号里那个 commit 就是它自己是从哪份源码编出来的。它在
# android.googlesource.com/toolchain/llvm-project 的 refs/heads/llvm-r522817 上，
# 是分支头 —— `git ls-remote` 对得上，所以按分支名浅取就行，不需要 sha-in-want。
#
# **Google 的 patches/ 不用打。** toolchain/llvm_android 里那 70 多个补丁是
# 「怎么造出这个分支」的配方，分支上的代码已经是打完的结果 —— clang 报的
# 就是这个 commit，它编的就是这份。别再打一遍。
#
# ---------------------------------------------------------------------------
# cmake flags 抄哪儿：toolchain/llvm_android 的 build.py。
#
# 那是 Google 编 NDK 这份 clang 用的脚本，等价于别的工具那边的 Android.bp。
# 对应的版本是 commit 7aecce1（"Update stable branch to clang-r522817"），
# 下面每个 -D 都能在 base_builders.py / builders.py 里找到出处。
#
# **最要紧的是它没设什么**：`CLANG_DEFAULT_RTLIB` / `CLANG_DEFAULT_UNWINDLIB` /
# `CLANG_DEFAULT_CXX_STDLIB` 一个都没有。上游 clang 的 driver 自己就认识
# Android：
#
#   clang/lib/Driver/ToolChains/Linux.cpp:339  isAndroid() -> RLT_CompilerRT
#   clang/lib/Driver/ToolChains/Linux.cpp:351  isAndroid() -> CST_Libcxx
#   clang/lib/Driver/ToolChain.cpp             rtlib 是 compiler-rt 且 isAndroid()
#                                              -> UNW_CompilerRT
#
# 这三处在 Google 那份和上游 llvmorg-18.1.3 里**逐字一样**（对过 diff）。
# 所以这三个变量必须**留空**。设了反而会盖掉 driver 的判断。
# README 第四节原来把「发行版 clang 要补三个 flag」的根因写反了，已改。
#
# ---------------------------------------------------------------------------
# 跟 Google 的差别（都是有意的，别假装没有）：
#
#   1. 不做 +pgo / +bolt / +lto / +mlgo。那四样要 profile 数据、要 BOLT 跑
#      instrument-再优化、要两阶段 LTO，是几倍的机时。它们**只影响编译器自己
#      跑多快、多大**，不影响它生成什么代码 —— 这条不是我说的，是
#      `--verify` 第 4 步在验的：拿官方二进制编出来的目标码哈希，比对我们编的。
#   2. 只编 clang;lld。Google 还编 clang-tools-extra;polly;bolt(;lldb)。
#      少的是 clangd / clang-tidy / clang-format / llvm-bolt / lldb。
#      要哪个再往 LLVM_ENABLE_PROJECTS 里加，代价是时间。
#   3. LLVM_ENABLE_LIBCXX=OFF。Google 用他们 stage1 编出来的 libc++，我们没有
#      stage1。改用发行版的 libstdc++ 并 -static-libstdc++ 静态链进去 ——
#      官方 clang-18 的 NEEDED 里也没有 libc++/libstdc++（只有 libgcc_s、libc、
#      libz 等），这一点是对齐的。**编译器自己用哪个 C++ 库，不影响它的输出。**
#   4. LLVM_INCLUDE_TESTS=OFF。省掉 gtest 和一大堆 unittest 的编译。
#      代价：跑不了 check-clang。
#   5. LLVM_BUILD_LLVM_DYLIB=OFF。Google 设 ON，但 NDK 的 lib/ 里根本没有
#      libLLVM*.so（数过），说明打包时没带上。不编能省一次大链接。
#
# **原来还有第六处，是错的，已经改回来了**：LLVM_ENABLE_ZSTD。
# 当初设成 OFF 是为了少一个依赖，判断成「无害」。不是。
# NDK sysroot 里的 libc.a **用 ZSTD 压了 debug 段**（.debug_str_offsets 等），
# lld 不带 zstd 支持就链不了任何静态的 Android 二进制：
#
#     ld.lld: error: libc.a(malloc_limit.o):(.debug_str_offsets) is compressed
#     with ELFCOMPRESS_ZSTD, but lld is not built with zstd support
#
# Google 的 base_builders.py:752 是 LLVM_ENABLE_ZSTD=FORCE_ON +
# LLVM_USE_STATIC_ZSTD=ON，照抄就对了。
#
# **这个错在 x86_64 上完全照得出来 —— 是测试写漏了，不是环境的限制。**
# 一开始我以为是「结构性照不出来」（x86 上编 Android 目标用的是 NDK 自带的
# 官方 lld），随手拿容器里那份 ZSTD=OFF 的产物一试，当场复现。
# 真正的原因是 --verify 第 6 步**只链了一个 .so**，动态链碰不到 libc.a；
# sysroot 里那些 ZSTD 压过的 .a 只有静态链才会被拆开读。
# 少一条测试就是少一条，别拿「环境不同」当解释。
# 现在第 6 步是两条：编 .so，再静态链一个可执行文件。
#
# sysroot/ 和 lib/clang/<ver>/ **不编**，从 NDK 自带的 linux-x86_64 那份拷。
# 那两块是**目标产物**（bionic 头文件和库、compiler-rt 的 android 运行时），
# 跟 host 是什么架构无关 —— 薄壳早就靠软链这两块跑通过 ndk-build。
# 拷（不是软链）是为了这份 prebuilt 能单独打包分发。
# ---------------------------------------------------------------------------

set -uo pipefail

# 跟 tools/build-common.sh 里的一样。这里没 source 它，理由见开头。
die()  { printf '\n  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1" >&2; }

# file(1) 是硬依赖：下面用 `case "$(file -b …)" in *ELF*)` 当闸门的地方，
# file 一缺就是空串 -> 全部 continue -> 检查空转报绿。实测过（见 docs/zh/LESSONS.md）。
command -v file >/dev/null || die "要 file(1)：sudo apt install -y file
    这个脚本靠它认二进制架构，缺了检查会静默空转。"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$REPO/work}"
# **按分支分目录**：换 NDK 版本要换 LLVM 分支，共用一个克隆目录会跟已有的那份
# 打架（HEAD 对不上 pin，报的错还指向别处）。默认分支保持老路径，别让现有的树白下。
if [ "${LLVM_BRANCH:-llvm-r522817}" = "llvm-r522817" ]; then
  SRC="$WORK/llvm/llvm-project"
else
  SRC="$WORK/llvm-${LLVM_BRANCH#llvm-}/llvm-project"
fi
# **构建目录也要按分支分**。只把源码目录分开是不够的：cmake 的 build 目录记着
# 它当初配置用的源码路径，换个源码去复用会直接报
#   CMake Error: The source "…/llvm/CMakeLists.txt" does not match the source "…"
# （实测第二次尝试就栽在这儿 —— 幸好 cmake 拒绝了，不然会编出一锅混的）。
if [ "${LLVM_BRANCH:-llvm-r522817}" = "llvm-r522817" ]; then
  BUILD="$WORK/llvm/build"
else
  BUILD="$WORK/llvm-${LLVM_BRANCH#llvm-}/build"
fi

# NDK r27b 那份 clang 的源码 pin。换 NDK 版本这两行都要跟着换 ——
# **默认值可以用环境变量覆盖**，tools/build-ndk-version.sh 就是这么换的
# （它去读目标 NDK 的 AndroidVersion.txt，不靠人记）。
# 对法：读新 NDK 的 bin/clang --version，括号里就是。
LLVM_BRANCH="${LLVM_BRANCH:-llvm-r522817}"
# 钉死的提交号。**换新 NDK 版本时还不知道该钉哪个** —— 这时传 LLVM_PIN=auto：
# 取分支 tip，靠下面那条「NDK 的 clang_source_info.md 基点必须出现在 HEAD 里」
# 的交叉验证把关（那条是数据驱动的，比人填的 pin 更硬），编完把 HEAD 打印出来，
# 由人抄回这里变成新的 pin。
LLVM_PIN="${LLVM_PIN:-d8003a456d14a3deb8054cdaa529ffbf02d9b262}"
LLVM_URL=https://android.googlesource.com/toolchain/llvm-project
# AndroidVersion.txt 里写的两行，用来核对拿来嫁接 sysroot 的 NDK 是不是同一版
NDK_CLANG_VER="${NDK_CLANG_VER:-18.0.2}"
NDK_CLANG_REV="${NDK_CLANG_REV:-r522817b}"

case "$(uname -m)" in
  x86_64)        HOST_TAG=linux-x86_64 ;;
  aarch64|arm64) HOST_TAG=linux-aarch64 ;;
  *) die "没见过的架构 $(uname -m)" ;;
esac
# 默认产物目录。LLVM_OUT 可以指到别处 —— 已经装进 NDK 的那份、或者官方那份
# （拿官方的树跑 --verify 是**校准测试本身**的办法：黄金值就是从它录的，
#  它必须全绿；换成薄壳/发行版 clang 必须在第 3 步红。两头都试过。）
OUT="${LLVM_OUT:-$WORK/out/llvm/$HOST_TAG}"

# 开头就把这个脚本自己是哪一版打出来 —— 「你跑的是哪一版」这个问题，
# 让它自己回答，别每次靠人去查。理由见 tools/build-common.sh 里同名函数。
_rev=$(git -C "$REPO" log -1 --format='%h %ad' --date=short -- "${BASH_SOURCE[0]}" 2>/dev/null)
printf '  \033[2m%s @ %s\033[0m\n' "$(basename "${BASH_SOURCE[0]}")" "${_rev:-（不在 git 里）}"

DO_FETCH=1 DO_BUILD=1 DO_VERIFY=1
case "${1:-}" in
  --fetch)  DO_BUILD=0; DO_VERIFY=0 ;;
  --build)  DO_FETCH=0; DO_VERIFY=0 ;;
  --verify) DO_FETCH=0; DO_BUILD=0 ;;
  "") ;;
  *) die "不认识的参数：$1" ;;
esac

find_ndk() {
  NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK:-}}"
  if [ -z "$NDK" ]; then
    for c in "$WORK"/android-ndk-* "${ANDROID_HOME:-}"/ndk/* "${ANDROID_SDK_ROOT:-}"/ndk/*; do
      [ -d "$c/toolchains/llvm/prebuilt" ] && { NDK="$c"; break; }
    done
  fi
  [ -n "$NDK" ] && [ -d "$NDK/toolchains/llvm/prebuilt" ] \
    || die "找不到 NDK。设 ANDROID_NDK_HOME，或者把它放到 $WORK/android-ndk-*"
  NDK=$(cd "$NDK" && pwd)
  X86="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
  [ -d "$X86" ] || die "$NDK 里没有 linux-x86_64 那份 —— sysroot 和 lib/clang 要从它那儿拷"
  local av="$X86/AndroidVersion.txt"
  [ -f "$av" ] || die "$av 不在"
  if ! grep -qx "$NDK_CLANG_VER" "$av" || ! grep -qx "based on $NDK_CLANG_REV" "$av"; then
    die "NDK 里的 clang 不是 $NDK_CLANG_VER / $NDK_CLANG_REV：

$(sed 's/^/      /' "$av")

    嫁接过来的 sysroot 和 lib/clang 必须跟编出来的 clang 同版本，
    混着用等于拿这个版本的编译器去配另一个版本的运行时。
    换 NDK，或者把脚本顶上的 LLVM_BRANCH / LLVM_PIN / NDK_CLANG_* 一起改。"
  fi
  ok "NDK $NDK（clang $NDK_CLANG_VER，$NDK_CLANG_REV）"

  # ------------------------------------------------------------------
  # **把「提交」和「字母」这两个人填的常量接起来。**
  #
  # 上面已经验了两件事：NDK 自报的 clang 是不是 $NDK_CLANG_VER/$NDK_CLANG_REV，
  # 以及我们 clone 到的 HEAD 是不是 $LLVM_PIN。但**这两条之间没有桥** ——
  # 谁改了其中一个忘了改另一个，编出来的 clang 会被盖上一个它并不对应的
  # 「based on rXXXXXXx」戳，而所有检查照样绿。
  #
  # NDK 自带的 clang_source_info.md 第一行写着它那份 clang 的上游基点：
  #     Base revision: [3c92011b600bdf70424e2547594dd461fe411a41](…)
  # 而 Google 那条 llvm-rXXXXXX 分支的头一个提交就是「Merge <基点> for LLVM
  # update to XXXXXX」。所以拿基点去我们 HEAD 的提交信息里找，找得到就说明
  # **我们编的源码正是这份 NDK 那份 clang 的基点**。
  #
  # 浅克隆（--depth 1）没有历史，所以不能用 merge-base；查提交信息是能做的
  # 最强的一条，而且它正好会在「分支被 respin、tip 换成别的 cherry-pick」时变红。
  local csi="$X86/clang_source_info.md"
  if [ ! -f "$csi" ]; then
    note "NDK 里没有 clang_source_info.md —— **提交号和 $NDK_CLANG_REV 这个戳没交叉验过**"
  elif [ ! -d "$SRC/.git" ]; then
    note "还没取源码，跳过提交号交叉验证（--fetch 时会做）"
  else
    local base msg
    base=$(sed -n 's/^Base revision: \[\([0-9a-f]\{40\}\).*/\1/p' "$csi" | head -1)
    if [ -z "$base" ]; then
      note "clang_source_info.md 里读不出 Base revision —— 没交叉验"
    else
      msg=$(git -C "$SRC" log -1 --format=%B 2>/dev/null)
      # **按前缀比，别按全长。** Google 那条合并提交的信息里写的是**短 sha**
      # （"Merge 3c92011b60 for LLVM update to 522817"），拿 40 位全长去 grep
      # 一定找不到 —— 第一版就是这么误报的。10 位十六进制已经足够强。
      case "$msg$( git -C "$SRC" rev-parse HEAD 2>/dev/null)" in
        *"${base:0:10}"*) ok "交叉验过：NDK 那份 clang 的基点 ${base:0:12} 就在我们 HEAD 的提交信息里" ;;
        *) die "**编的源码跟这份 NDK 对不上。**
      NDK 说它那份 clang 的基点是   $base
      我们 HEAD（$LLVM_PIN）的提交信息里找不到它。

    可能是：换了 NDK 版本却没改 LLVM_PIN；或者改了 LLVM_PIN 却没改
    NDK_CLANG_REV（那样编出来会盖一个不对应的「based on」戳）。
    tools/build-ndk-version.sh 会从目标 NDK 读出该用哪三个值。" ;;
      esac
    fi
  fi
}

# ---------------------------------------------------------------------- fetch
if [ "$DO_FETCH" = 1 ]; then
  step "查家伙什"
  for t in git cmake ninja python3; do
    command -v "$t" >/dev/null || die "没有 $t：sudo apt install -y git cmake ninja-build python3"
  done
  cmv=$(cmake --version | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
  [ "$(printf '%s\n3.20\n' "$cmv" | sort -V | head -1)" = 3.20 ] \
    || die "cmake 太老（$cmv），LLVM 18 要 >= 3.20"
  command -v ld.lld >/dev/null || command -v ld.lld-18 >/dev/null \
    || die "没有 lld：sudo apt install -y lld
    （LLVM_USE_LINKER=lld，抄 Google 的。用 bfd 链 clang 会慢很多也更吃内存）"
  command -v clang >/dev/null || command -v g++ >/dev/null \
    || die "没有 C++ 编译器：sudo apt install -y clang  或  sudo apt install -y g++"
  [ -f /usr/include/zlib.h ] || warn "没找到 zlib.h，官方 clang 是链 libz 的：sudo apt install -y zlib1g-dev"
  # zstd 不是可选的，理由见开头那段。静态链所以要 .a。
  [ -f /usr/include/zstd.h ] || die "没有 zstd.h：sudo apt install -y libzstd-dev
    **这个不能省。** NDK sysroot 里的 libc.a 用 ZSTD 压了 debug 段，
    lld 不带 zstd 支持就链不了静态的 Android 二进制。"
  ls /usr/lib/*/libzstd.a >/dev/null 2>&1 || ls /usr/lib/libzstd.a >/dev/null 2>&1 \
    || die "有 zstd.h 但没有 libzstd.a（LLVM_USE_STATIC_ZSTD=ON 要它）：
    sudo apt install -y libzstd-dev"
  ok "cmake $cmv，ninja $(ninja --version)，$(nproc) 核"

  step "查磁盘"
  avail=$(df -BG --output=avail "$WORK" 2>/dev/null | tail -1 | tr -dc '0-9')
  note "$WORK 还剩 ${avail} GB"
  [ "${avail:-0}" -ge "${NEED_GB:-12}" ] || die \
"至少要 ${NEED_GB:-12} GB。实测（x86_64，4 核）：源码 2.1 + build 3.4 + 装出来 1.8
    = 7.3 GB，留点余量算 12。想硬来：NEED_GB=8 tools/build-llvm.sh --fetch"
  ok "够"

  step "取源码"
  if [ -d "$SRC/.git" ]; then
    note "$SRC 已经在了"
  else
    mkdir -p "$(dirname "$SRC")"
    note "$LLVM_URL 分支 $LLVM_BRANCH（浅取，约 2.1 GB，看网速要几分钟到几十分钟）"
    git clone --depth 1 --single-branch --branch "$LLVM_BRANCH" "$LLVM_URL" "$SRC" \
      || die "clone 失败"
  fi
  head=$(git -C "$SRC" rev-parse HEAD)
  if [ "$LLVM_PIN" = auto ]; then
    note "LLVM_PIN=auto：分支 tip 是 $head"
    note "**编完把它抄进脚本顶上的 LLVM_PIN**，下次才有确定性。"
    LLVM_PIN="$head"
  fi
  [ "$head" = "$LLVM_PIN" ] || die "取下来的不是 pin 的那个 commit：
      拿到  $head
      要的  $LLVM_PIN
    多半是 Google 往 $LLVM_BRANCH 上又推了 respin。**别将就编** ——
    先确认 NDK 里的 clang --version 现在报的是哪个 commit，对上了再改脚本顶上的 LLVM_PIN。"
  ok "源码在 $SRC，HEAD = $LLVM_PIN"
  find_ndk
fi

# ---------------------------------------------------------------------- build
if [ "$DO_BUILD" = 1 ]; then
  [ -d "$SRC/llvm" ] || die "找不到源码，先跑 tools/build-llvm.sh --fetch"
  find_ndk

  CC_BIN=$(command -v clang || command -v gcc)
  CXX_BIN=$(command -v clang++ || command -v g++)
  LINK_JOBS=${LINK_JOBS:-2}   # 链接峰值内存大，4 核 16 GB 上并行 2 个是稳的

  step "cmake 配置"
  note "编译器  $CXX_BIN"
  note "装到    $OUT"
  cmake -G Ninja -S "$SRC/llvm" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$OUT" \
    -DCMAKE_C_COMPILER="$CC_BIN" \
    -DCMAKE_CXX_COMPILER="$CXX_BIN" \
    -DLLVM_ENABLE_PROJECTS="clang;lld" \
    -DLLVM_TARGETS_TO_BUILD="AArch64;ARM;BPF;RISCV;WebAssembly;X86" \
    -DLLVM_ENABLE_ASSERTIONS=OFF \
    -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_ENABLE_THREADS=ON \
    -DLLVM_ENABLE_PLUGINS=OFF \
    -DLLVM_ENABLE_ZSTD=FORCE_ON \
    -DLLVM_USE_STATIC_ZSTD=ON \
    -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_ENABLE_LIBEDIT=OFF \
    -DLLVM_ENABLE_LIBCXX=OFF \
    -DLLVM_INCLUDE_GO_TESTS=OFF \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_BUILD_LLVM_DYLIB=OFF \
    -DLLVM_INSTALL_TOOLCHAIN_ONLY=OFF \
    -DLLVM_USE_LINKER=lld \
    -DLLVM_PARALLEL_LINK_JOBS="$LINK_JOBS" \
    -DLLVM_VERSION_PATCH=2 \
    -DLLVM_VERSION_SUFFIX="" \
    -DCLANG_REPOSITORY_STRING="$LLVM_URL" \
    -DCLANG_VENDOR="android-sdk-linux-arm64 (no pgo/bolt/lto/mlgo, based on $NDK_CLANG_REV)" \
    -DBUG_REPORT_URL="https://github.com/android-ndk/ndk/issues" \
    -DCLANG_DEFAULT_LINKER=lld \
    -DCLANG_DEFAULT_OBJCOPY=llvm-objcopy \
    -DCMAKE_PLATFORM_NO_VERSIONED_SONAME=ON \
    -DCMAKE_EXE_LINKER_FLAGS="-static-libstdc++" \
    -DCMAKE_SHARED_LINKER_FLAGS="-static-libstdc++" \
    || die "cmake 配置失败"
  ok "配置完成"
  # 顺手把「一个都不许设」这件事验一遍：配错了这里就拦下来，别等到编完两小时。
  for v in CLANG_DEFAULT_RTLIB CLANG_DEFAULT_UNWINDLIB CLANG_DEFAULT_CXX_STDLIB; do
    val=$(grep -E "^$v:" "$BUILD/CMakeCache.txt" | cut -d= -f2-)
    [ -z "$val" ] || die "$v 被设成了「$val」。必须留空 —— 见脚本开头。"
  done
  ok "三个 CLANG_DEFAULT_* 都是空的（Google 也没设）"

  step "ninja（$(nproc) 核，链接并行 $LINK_JOBS）"
  note "这一步很久。想换个终端看进度：ninja -C $BUILD -n | wc -l"
  t0=$(date +%s)
  ninja -C "$BUILD" || die "编译失败"
  t1=$(date +%s)
  ok "编完，用了 $(( (t1-t0)/60 )) 分钟"

  step "安装到 $OUT"
  rm -rf "$OUT"
  ninja -C "$BUILD" install >/dev/null || die "install 失败"
  # 装完再裁。上面那行 -DLLVM_INSTALL_TOOLCHAIN_ONLY=OFF 是**显式写 OFF**，
  # 不是不写 —— cmake 的缓存变量删掉 -D 是不会变回默认值的，改配方之后
  # 老的 build 目录里还留着上一次的 ON。
  # **不要**用 LLVM_INSTALL_TOOLCHAIN_ONLY=ON 去省下面这几行 rm ——
  # 那个开关同时把 llvm-config / llvm-link / llvm-as / llvm-dis / llvm-dwarfdump /
  # llvm-ifs / llvm-lipo / llvm-modextract / llvm-cfi-verify / dsymutil 这些
  # **NDK 实际带着的**工具也挡在了 install 之外，连 llvm-readelf -> llvm-readobj
  # 这种符号链接都不装（build 目录里明明是有的）。第一版就是这么漏的，
  # 第 5 步逐个对官方的 bin/ 才照出来。
  rm -rf "$OUT/include" "$OUT/lib/cmake"
  find "$OUT/lib" -maxdepth 1 -name '*.a' -delete
  ok "bin/ 里 $(ls "$OUT/bin" | wc -l) 个（已裁掉 include/ 和 lib/cmake/、lib/*.a）"

  step "裁到官方那份的清单"
  # LLVM 全套装出来比 NDK 实际带的多 1.2 GB：opt / llc / bugpoint / clang-repl /
  # llvm-lto / llvm-reduce 这些是**改 LLVM 自己**用的，NDK 一个都不带。
  # 判据还是官方那份 —— 它有什么我们留什么。多出来的删掉，删了多少打出来。
  n_extra=0 sz_extra=0
  while IFS= read -r f; do
    [ -e "$OUT/bin/$f" ] || continue
    sz_extra=$((sz_extra + $(stat -c%s "$OUT/bin/$f" 2>/dev/null || echo 0)))
    rm -f "$OUT/bin/$f"; n_extra=$((n_extra + 1))
  done < <(comm -13 <(ls "$X86/bin" | sort) <(ls "$OUT/bin" | sort))
  ok "删掉 $n_extra 个官方不带的（$((sz_extra / 1024 / 1024)) MB）——都是改 LLVM 自己用的工具"

  step "补官方 bin/ 里的符号链接"
  # 官方那份的 bin/ 有 14 个非三元组的符号链接（ld -> ld.lld、llvm-readelf ->
  # llvm-readobj 等）。LLVM 的 install 只做其中一部分，**ld 这个是 Google 自己
  # 加的**。照官方有什么补什么，别一个个手写死。
  n_ln=0
  while IFS= read -r pair; do
    name=${pair%% *}; tgt=${pair##* }
    [ -e "$OUT/bin/$name" ] && continue
    [ -e "$OUT/bin/$tgt" ] || continue
    ln -s "$tgt" "$OUT/bin/$name"; n_ln=$((n_ln + 1))
  done < <(find "$X86/bin" -maxdepth 1 -type l -printf '%f %l\n' | grep -vE '^[a-z0-9_]+-linux-android')
  ok "补了 $n_ln 个（install 没做的那些）"

  step "嫁接 sysroot 和 lib/clang（从 $HOST_TAG 之外那份拷，它们跟 host 无关）"
  rm -rf "$OUT/sysroot" "$OUT/lib/clang"
  cp -a "$X86/sysroot" "$OUT/sysroot" || die "拷 sysroot 失败"
  mkdir -p "$OUT/lib"
  cp -a "$X86/lib/clang" "$OUT/lib/clang" || die "拷 lib/clang 失败"
  ok "sysroot $(du -sh "$OUT/sysroot" | cut -f1)，lib/clang $(du -sh "$OUT/lib/clang" | cut -f1)"

  step "补三元组前缀的包装脚本（照抄官方那份有哪些就做哪些）"
  n=0
  for f in "$X86"/bin/*-linux-android*-clang "$X86"/bin/*-linux-android*-clang++; do
    [ -f "$f" ] || continue
    base=$(basename "$f"); case "$base" in *.cmd) continue ;; esac
    triple=${base%-clang}; triple=${triple%-clang++}
    drv=clang; case "$base" in *-clang++) drv=clang++ ;; esac
    cat > "$OUT/bin/$base" <<WRAPT
#!/usr/bin/env bash
bin_dir=\$(dirname "\$0")
if [ "\$1" != "-cc1" ]; then
    "\$bin_dir/$drv" --target=$triple "\$@"
else
    # Target is already an argument.
    "\$bin_dir/$drv" "\$@"
fi
WRAPT
    chmod +x "$OUT/bin/$base"; n=$((n+1))
  done
  ok "$n 个"

  step "python3"
  # 官方那份带一整个 CPython。少了它 ndk-build 会**静默降级**成裸 `python`——
  # Ubuntu 22.04+ 没这个名字，$(shell ...) 全返回空，APP_PLATFORM 之类悄悄取
  # 默认值（README 第四节 M1 那张表，另见 patches/ndk/0005）。
  #
  # tools/build-python.sh 编出来的那份在的话就拷进来（自足）；不在就软链系统的
  # （够用，但那样这份 prebuilt 没法单独打包分发）。
  # **跟着 PYTHON_OUT 走。** 写死的话，按版本分目录编 python 之后这里找不到，
  # 会悄悄退回「软链系统 python3」那条兜底路 —— 补丁 0005 专门防的就是静默降级，
  # 结果自己在这儿留了一个。
  PY_BUILT="${PYTHON_OUT:-$WORK/out/python3/$HOST_TAG}"
  rm -rf "$OUT/python3"
  if [ -x "$PY_BUILT/bin/python3" ]; then
    cp -a "$PY_BUILT" "$OUT/python3" || die "拷 python3 失败"
    ok "python3 $(du -sh "$OUT/python3" | cut -f1)（自己编的，来自 tools/build-python.sh）"
  else
    mkdir -p "$OUT/python3/bin"
    if p=$(command -v python3); then
      ln -sf "$p" "$OUT/python3/bin/python3"
      warn "python3 软链到 $p —— **不自足**。要自己编那份：
    tools/build-python.sh --fetch && tools/build-python.sh --build
    然后重跑本脚本的 --build（它在就会拷进来）"
    else
      warn "系统里没有 python3，ndk-build 会静默降级。装一个：sudo apt install -y python3"
    fi
  fi

  printf '%s\nbased on %s\nsee clang_source_info.md in the official NDK for the cherry-pick list\n' \
    "$NDK_CLANG_VER" "$NDK_CLANG_REV" > "$OUT/AndroidVersion.txt"

  # ---------------------------------------------------------------- 腾地方
# **给 CI 用的**：GitHub 的托管 runner 只有 14 GB 盘，而这条链的峰值是
# 源码 2.1 + build 3.5 + 装出来 1.7 ≈ 7.2 GB（实测）。装完之后 build/ 和源码
# 就没用了，删掉只剩 1.7 GB —— 后面的打包步骤（或 artifact 上传）就宽裕了。
# 默认不删：本机开发时留着能增量重编，删了下次要重下 2.1 GB。
if [ "${PRUNE_AFTER_INSTALL:-0}" = 1 ]; then
  step "腾地方（PRUNE_AFTER_INSTALL=1）"
  before=$(df -m "$WORK" | tail -1 | awk '{print $4}')
  rm -rf "$BUILD" "$SRC"
  after=$(df -m "$WORK" | tail -1 | awk '{print $4}')
  ok "删掉 build/ 和源码，腾出 $(( (after-before)/1024 )) GB；产物 $(du -sh "$OUT" | cut -f1) 留着"
  note "下次要再编得重新 --fetch（2.1 GB）"
fi

step "编好了"
  note "整份 $(du -sh "$OUT" | cut -f1)：$OUT"
  note ""
  note "验它："
  note "    tools/build-llvm.sh --verify"
  note ""
  note "换掉 NDK 里那份（薄壳或者旧的）："
  note "    rm -rf $NDK/toolchains/llvm/prebuilt/$HOST_TAG"
  note "    cp -a $OUT $NDK/toolchains/llvm/prebuilt/$HOST_TAG"
fi

# --------------------------------------------------------------------- verify
if [ "$DO_VERIFY" = 1 ]; then
  BIN="$OUT/bin/clang"
  [ -x "$BIN" ] || die "$BIN 不在，先跑 tools/build-llvm.sh --build"
  find_ndk
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

  step "验自己编的这份 clang"

  # ---- 1/6 先来一条必须失败的（第五节第 5 条）----
  step "1/6  先让它红一次：拿它编一份故意写错的 C"
  printf 'int main(void) { retrun 0; }\n' > "$T/bad.c"
  if "$BIN" --target=aarch64-linux-android21 -c "$T/bad.c" -o "$T/bad.o" 2>"$T/bad.log"; then
    die "编过了？！那说明下面几步测的根本不是编译这件事"
  fi
  grep -q "error:" "$T/bad.log" || die "失败了但没报 error:，看看 $T/bad.log"
  ok "红了，报的是 $(grep -m1 'error:' "$T/bad.log" | sed 's/.*error: //')"

  # ---- 2/6 版本 ----
  step "2/6  版本串"
  ver=$("$BIN" --version | head -1)
  note "$ver"
  case "$ver" in
    *"clang version $NDK_CLANG_VER "*) ;;
    *)
      # **偏差可以放行，但必须显式、必须留痕。**
      # 我们编的是 Google 那条 llvm-rXXXXXX 分支的 tip，而 NDK 是从该分支某个
      # 更早的点切出去的 —— 分支往前走了，版本号就对不上。r27 那次严丝合缝是
      # 运气（tip 恰好停在 r27b 那点），r28 就差一个补丁位（NDK 19.0.1 / 我们 19.0.2）。
      #
      # 2026-09-01 实测过这个偏差的后果：资源目录按大版本命名（lib/clang/19）所以
      # 对得上；ndk-build 和 CMake 两条路都编得出 .so；用它编的 APK 装进真机
      # （Android 16 / arm64-v8a）跑出了正确结果，设备上那份 APK 跟本地 sha256 一致。
      # 所以放行是有依据的 —— 但**不能默默放行**，要 ALLOW_CLANG_VER_SKEW=1 明说。
      if [ "${ALLOW_CLANG_VER_SKEW:-0}" = 1 ]; then
        warn "**版本有偏差**：NDK 说 $NDK_CLANG_VER，我们编出来是 $(grep -oE 'clang version [0-9.]+' <<<"$ver" | head -1)"
        note "运行时件（compiler-rt / sysroot）来自 NDK，编译器是我们的 —— 混用。"
        note "已知它能用（见 docs/VERSIONS.md），但这条偏差要写进包的 PROVENANCE。"
      else
        die "版本不是 $NDK_CLANG_VER：
$(head -1 <<<"$ver" | sed 's/^/      /')

    我们编的是分支 tip，而这份 NDK 是从更早的点切出去的。
    确认过后果可以接受的话，用 ALLOW_CLANG_VER_SKEW=1 显式放行 —— 别默默放。"
      fi ;;
  esac
  # --verify 不 clone，所以这里的 auto 还没被换成真实提交 —— 从源码树读。
  if [ "$LLVM_PIN" = auto ]; then
    LLVM_PIN=$(git -C "$SRC" rev-parse HEAD 2>/dev/null) \
      && note "LLVM_PIN=auto：按源码树 HEAD 算，$LLVM_PIN" \
      || die "LLVM_PIN=auto 但 $SRC 不是 git 树"
  fi
  case "$ver" in
    *"$LLVM_URL $LLVM_PIN"*) ;;
    *) die "源码 commit 不是 $LLVM_PIN —— 编的不是 pin 的那份" ;;
  esac
  ok "clang $NDK_CLANG_VER，源码 commit 对得上"
  note "（前缀那段跟官方不一样是**故意的**：官方是 +pgo/+bolt/+lto/+mlgo，我们没做）"

  # ---- 3/6 驱动行为的黄金对照 ----
  #
  # 这是这个脚本里最值钱的一步。官方 x86_64 的 clang **在 ARM64 上跑不了**
  # （exit 126，跟 aapt2 那次一模一样），所以参照物不能现跑，只能是**事先录
  # 好的黄金值**：在能跑官方二进制的机器上录一次，之后逐 token 比。
  # 第五节第 6 条。
  #
  # 录的是 `clang++ --target=aarch64-linux-android21 -### g.cpp -o g` 的两条
  # 命令行（-cc1 一条、ld.lld 一条），归一化掉三处必然不同的东西：
  #   @ROOT@  工具链根目录（官方在 .../linux-x86_64，我们在别处）
  #   @CWD@   -fdebug-compilation-dir / -fcoverage-compilation-dir，是当前目录
  #   @TMPO@  中间 .o 的临时文件名，带随机后缀
  # 还有 `bin/../sysroot` 和 `sysroot` 两种写法，指的是同一个目录，一并归一。
  #
  # 它有判别力吗？有。发行版的 clang 18.1.3 在这条上是**对不上**的：
  #   -cc1 多一个 -fskip-odr-check-in-gmf（18.1.x 才进的 cherry-pick）
  #   -cc1 的 target-feature 多一个 +fp-armv8，顺序也不同
  #   链接行多一个 --build-id（Debian 给 clang 打的默认值）
  #   不补 -rtlib=platform -unwindlib=platform 的话还差 compiler-rt 和 libunwind
  # **黄金值是跟 clang 版本绑死的。** 下面那段是照 clang 18.0.2（NDK r27）录的；
  # clang 19 展开 AArch64 target-feature 的方式变了（多一个 +fp-armv8，顺序也不同），
  # 拿 18 的黄金值去比 19 必红 —— 那是版本差异，不是我们编错了。
  # 要给别的版本补黄金值，得在**能跑那份官方 x86_64 clang 的机器上**重录一份。
  # 这台跑不了（qemu 已卸，也不该为此装回来），所以照仓库的规矩：**说没验，别假装验了**。
  GOLDEN_FOR=18.0.2
  if [ "$NDK_CLANG_VER" != "$GOLDEN_FOR" ]; then
    note "黄金值是照 clang $GOLDEN_FOR 录的，这次是 $NDK_CLANG_VER —— **这一步没验**"
    note "补法：在能跑官方 x86_64 clang 的机器上重录一段，按版本存。"
  else
  step "3/6  驱动行为跟官方逐 token 比（黄金值）"
  cat > "$T/g.cpp" <<'GSRC'
#include <string>
std::string f(int n){ return std::to_string(n); }
GSRC
  ( cd "$T" && "$OUT/bin/clang++" --target=aarch64-linux-android21 -### g.cpp -o g 2>&1 ) \
    | sed "s|$OUT|@ROOT@|g" | sed 's|@ROOT@/bin/\.\./|@ROOT@/|g' \
    | grep -E '^ *"' | sed "s|$T|@CWD@|g" | sed 's|"/tmp/[^"]*\.o"|"@TMPO@"|g' \
    | sed 's/^ *//' | tr ' ' '\n' | grep -v '^$' > "$T/got.txt"
  sed -n '/^GOLDEN_LINK_TOKENS$/,/^GOLDEN_LINK_TOKENS_END$/p' "${BASH_SOURCE[0]}" \
    | sed '1d;$d' > "$T/want.txt"
  [ -s "$T/want.txt" ] || die "脚本里的黄金值段落读不出来"
  if ! diff -u "$T/want.txt" "$T/got.txt" > "$T/diff.txt"; then
    sed -n '1,60p' "$T/diff.txt" >&2
    die "驱动行为跟官方对不上（上面 - 是官方的，+ 是我们的）。
    差在 -cc1 那条 = 编译期默认值配错了；差在 ld.lld 那条 = 链接期默认值配错了。"
  fi
  ok "$(wc -l < "$T/want.txt") 个 token 全同"
  fi

  # ---- 4/6 目标码的黄金对照 ----
  #
  # 上一步验的是「它打算干什么」，这一步验「它真编出来的字节」。
  # 同样是录下来的哈希：官方 x86_64 clang 编同一份 golden.c 的结果。
  # 去掉 .comment 段再比 —— 那一段里是 CLANG_VENDOR 字符串，我们跟官方
  # **有意**不同，比它没意义。别的段（.text/.rodata/重定位/符号表）全比。
  #
  # 这一步同时是在验开头那句「不做 PGO/BOLT/LTO/MLGO 不影响生成的代码」：
  # 对不上就说明那句话是错的，而不是「差不多就行」。
  step "4/6  目标码跟官方逐字节比（黄金值）"
  cat > "$T/golden.c" <<'GOLDSRC'
/* 黄金样本的输入。改一个字节，下面写死的哈希就全部作废。 */
#include <stdint.h>
#include <stddef.h>

struct vec3 { double x, y, z; };

static uint32_t mix(uint32_t h, uint32_t k) {
  k *= 0xcc9e2d51u; k = (k << 15) | (k >> 17); k *= 0x1b873593u;
  h ^= k; h = (h << 13) | (h >> 19); return h * 5u + 0xe6546b64u;
}

uint32_t hash_words(const uint32_t *p, size_t n) {
  uint32_t h = 0;
  for (size_t i = 0; i < n; i++) h = mix(h, p[i]);
  return h ^ (uint32_t)n;
}

double dot(struct vec3 a, struct vec3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }

struct vec3 scale(struct vec3 v, double s) {
  struct vec3 r = { v.x * s, v.y * s, v.z * s };
  return r;
}

long sum_squares(const int *a, int n) {
  long s = 0;
  for (int i = 0; i < n; i++) s += (long)a[i] * a[i];
  return s;
}

int classify(int c) {
  switch (c) {
    case 0: case 1: case 2: return 10;
    case 7: return 20;
    case 8: case 9: return 30;
    case 100: return 40;
    default: return c < 0 ? -1 : 0;
  }
}

static long fact(long n) { return n < 2 ? 1 : n * fact(n - 1); }
long fact10(void) { return fact(10); }

unsigned udiv(unsigned a) { return a / 7u; }
GOLDSRC
  # 哈希跟「在哪个目录编」无关（试过换目录复现），但跟**源文件名**有关：
  # clang 会把它写进符号表的 STT_FILE。所以必须 cd 进去、用相对名 golden.c。
  gold_check() { # $1=triple  $2=期望哈希
    local o="$T/g-$1.o" n="$T/n-$1.o" got
    ( cd "$T" && "$BIN" --target="$1" -O2 -c golden.c -o "g-$1.o" ) || die "$1 编不过"
    "$OUT/bin/llvm-objcopy" --remove-section=.comment "$o" "$n" || die "objcopy 失败"
    got=$(sha256sum "$n" | cut -d' ' -f1)
    if [ "$got" != "$2" ]; then
      note "$1 对不上：官方 $2"
      note "$(printf '%*s' ${#1} '')          我们 $got"
      # make_f2fs 那次的教训：对不上时**当场把差在哪儿指出来**，别只报个哈希。
      "$OUT/bin/llvm-objcopy" -O binary --only-section=.text "$o" "$T/t.bin" 2>/dev/null \
        && note ".text 单独看：$(sha256sum "$T/t.bin" | cut -c1-16)…（.text 也不同 = 生成的代码就不一样；.text 相同 = 差在别的段）"
      die "$1 的目标码跟官方不一样"
    fi
    ok "$1  $got"
  }
  gold_check aarch64-linux-android21     4e440674e39e8d5710cfa70216601bc27d052733825b34fd2a6a442947f08058
  gold_check armv7a-linux-androideabi21  8694e7946236f109ea0bec81215046f945773df837b0700aa697689e3224e277

  # ---- 5/6 逐个对官方的 bin/ ----
  #
  # **别手写一张「应该有哪些工具」的清单** —— 第一版就是手写的九个，九个全在，
  # 而实际漏了十几个（llvm-config / llvm-link / llvm-as / llvm-dwarfdump …
  # 连 llvm-readelf 这种符号链接都没装）。手写的清单只能证明清单里那几个在。
  # 权威是官方那份 prebuilt 的 bin/，逐个比。
  #
  # 下面这张「知道没有」的名单是**唯一允许缺的**，每一条都要说得出为什么：
  # 格式：一行一个名字，`#` 之后是理由。**别把名字和理由混在一行里用空格分**——
  # 第一版就是那么写的，结果从理由里抠出了 `compiler-rt` 和 `2`（「见开头第 2 条」）
  # 两个根本不存在的条目混进名单。今天没影响结果，但**机制不成立**：
  # 理由里只要写到某个真实工具名，就会悄悄放行一个真缺口。下面还有一条自检。
  KNOWN_MISSING="
clang-tidy              # clang-tools-extra，没开（见脚本开头「跟 Google 的差别」）
clangd                  # 同上
clang-tidy.sh           # Google 自己加的包装脚本
lldb                    # lldb，没开
lldb-argdumper          # 同上
lldb.sh                 # 同上
llvm-bolt               # bolt，没开
merge-fdata             # 同上
sancov                  # compiler-rt 自带的工具，我们不编 compiler-rt（用 NDK 现成的）
sanstats                # 同上
yasm                    # 根本不是 LLVM 的东西，是另一个汇编器
bisect_driver.py        # Google 自己加的脚本
remote_toolchain_inputs # 同上
"
  step "5/6  bin/ 逐个对官方那份"
  allow=$(printf '%s\n' "$KNOWN_MISSING" | sed 's/#.*//' | tr -d ' \t' | grep -v '^$' | sort -u)
  # 自检：名单里的每一项都必须真的是官方 bin/ 里的条目。
  # 抠错了、写错了、官方哪天不带了，都在这儿拦下，而不是变成一条静默放行。
  ghost=$(comm -23 <(printf '%s\n' "$allow") <(ls "$X86/bin" | sort) | tr '\n' ' ')
  [ -z "$(echo "$ghost" | tr -d ' ')" ] || die "「知道没有」名单里有官方 bin/ 根本没有的条目：
      $ghost
    名单写错了。**这不是小事** —— 名单里多一个名字，就等于对那个名字静默放行。"
  miss=$(comm -23 \
    <(ls "$X86/bin" | grep -vE '^[a-z0-9_]+-linux-android|\.(cmd|exe|dll)$' | sort) \
    <(ls "$OUT/bin" | grep -vE '^[a-z0-9_]+-linux-android|\.(cmd|exe|dll)$' | sort) \
    | grep -vxF "$allow" | tr '\n' ' ')
  [ -z "$(echo "$miss" | tr -d ' ')" ] || die "官方 bin/ 里有、我们没有，而且不在「知道没有」名单里：
      $miss
    要么是 install 少装了（先怀疑这个），要么是真没编。别直接往名单里加。"
  ok "官方 $(ls "$X86/bin" | grep -vcE '^[a-z0-9_]+-linux-android') 个非三元组条目，除「知道没有」的 $(echo "$allow" | wc -l) 个外全有"
  # 在的还得真能跑
  bad=""
  for t in clang clang++ ld.lld llvm-ar llvm-nm llvm-objcopy llvm-strip llvm-readelf llvm-objdump llvm-config; do
    [ -e "$OUT/bin/$t" ] || continue
    "$OUT/bin/$t" --version >/dev/null 2>&1 || "$OUT/bin/$t" --help >/dev/null 2>&1 \
      || bad="$bad $t"
  done
  [ -z "$bad" ] || die "这几个在但跑不起来：$bad"
  ok "常用的那几个都能跑"

  # ---- 6/6 真编东西 ----
  #
  # 两条，**第二条是补上去的，起因是一次真机上的失败**：拿这份工具链编 adb 时
  #     ld.lld: error: libc.a(...):(.debug_str_offsets) is compressed with
  #     ELFCOMPRESS_ZSTD, but lld is not built with zstd support
  # 第一条（编 .so）链的是 libc.so，**碰不到 libc.a，所以它全绿也说明不了问题**。
  # 静态链才会把 sysroot 里那些 ZSTD 压过的 .a 拆开读。
  # 加完这条之后拿容器里那份 ZSTD=OFF 的产物验过，当场复现同样的报错 ——
  # 也就是说这个洞本来在 x86 上就该被堵住，是测试写漏了。
  step "6/6  真编一个 arm64-v8a 的 .so 出来"
  printf '#include <string>\nextern "C" const char* hi(){ static std::string s="hi"; return s.c_str(); }\n' > "$T/h.cpp"
  ( cd "$T" && "$OUT/bin/clang++" --target=aarch64-linux-android21 -shared -o libh.so h.cpp ) \
    || die "编不出来"
  f=$(file -b "$T/libh.so")
  note "$f"
  # file 的输出是「shared object, ARM aarch64」这个顺序，两个词分开判，别写成
  # 一个带顺序的通配 —— 第一版就是那么写的，拿官方的树一跑就红了。
  case "$f" in *"ARM aarch64"*) ;; *) die "编出来的不是 aarch64：$f" ;; esac
  case "$f" in *"shared object"*) ;; *) die "编出来的不是 shared object：$f" ;; esac
  _d=$("$OUT/bin/llvm-readelf" -d "$T/libh.so")   # 不走管道，见 docs/LESSONS.md
  case "$_d" in *"libc.so"*) ;; *) die "NEEDED 里没有 bionic 的 libc.so" ;; esac
  ok "是 aarch64 shared object，链的是 bionic"

  printf 'int main(void){ return 0; }\n' > "$T/s.c"
  ( cd "$T" && "$OUT/bin/clang" --target=aarch64-linux-android21 -static -o s s.c ) \
    || die "静态链失败。看看是不是这条：

    ld.lld: ... is compressed with ELFCOMPRESS_ZSTD, but lld is not built with
    zstd support

    那就是编 LLVM 时 zstd 没开。装 libzstd-dev 之后重跑 --build。
    NDK sysroot 里的 libc.a 用 ZSTD 压了 debug 段，链静态 Android 二进制绕不过去。"
  f=$(file -b "$T/s")
  case "$f" in *"statically linked"*) ;; *) die "编出来了但不是静态的：$f" ;; esac
  ok "静态链也过了（sysroot 里 ZSTD 压过的 libc.a 读得开）"

  step "6.5/6  python3"
  P3="$OUT/python3/bin/python3"
  if [ ! -x "$P3" ] || ! "$P3" --version >/dev/null 2>&1; then
    warn "$P3 不在或跑不起来 —— ndk-build 会静默降级成裸 python。"
  else
    # **判据是 sys.prefix，不是「文件在不在」。** 软链过去的系统 python 也能跑、
    # 也打得出版本号，区别在于它的 stdlib 在系统里，这份 prebuilt 就没法单独
    # 打包分发（M4 要用）。
    pfx=$("$P3" -c 'import sys;print(sys.prefix)' 2>/dev/null)
    case "$pfx" in
      "$OUT/python3")
        ok "自带 CPython $("$P3" -c 'import sys;print(sys.version.split()[0])')，sys.prefix 在工具链内 —— 自足" ;;
      *)
        note "python3/bin/python3 -> $(readlink -f "$P3" 2>/dev/null)"
        note "sys.prefix = $pfx —— **在工具链外面，也就是借系统的**。"
        note "够用（ndk-build 那五个脚本全是标准库），但这份 prebuilt 不自足，"
        note "没法单独打包分发。要补上："
        note "    tools/build-python.sh --fetch && tools/build-python.sh --build"
        note "    然后重跑 tools/build-llvm.sh --build" ;;
    esac
  fi

  step "这份 host 工具链是自己编的，可以用了"
  note "换掉 NDK 里那份："
  note "    rm -rf $NDK/toolchains/llvm/prebuilt/$HOST_TAG"
  note "    cp -a $OUT $NDK/toolchains/llvm/prebuilt/$HOST_TAG"
  note ""
  note "**没验的**：clang-tidy / clangd / lldb / llvm-bolt 这些没编（见开头第 2 条）。"
fi

exit 0

# 下面这段是第 3 步的黄金值，由 --verify 自己 sed 出来。别手改。
# 重录（要在**能跑官方 x86_64 二进制**的机器上）：
#   NDKP=<ndk>/toolchains/llvm/prebuilt/linux-x86_64
#   cd $(mktemp -d) && printf '#include <string>\nstd::string f(int n){ return std::to_string(n); }\n' > g.cpp
#   $NDKP/bin/clang++ --target=aarch64-linux-android21 -### g.cpp -o g 2>&1 \
#     | sed "s|$NDKP|@ROOT@|g" | sed 's|@ROOT@/bin/\.\./|@ROOT@/|g' | grep -E '^ *"' \
#     | sed "s|$PWD|@CWD@|g" | sed 's|"/tmp/[^"]*\.o"|"@TMPO@"|g' | sed 's/^ *//' \
#     | tr ' ' '\n' | grep -v '^$'
GOLDEN_LINK_TOKENS
"@ROOT@/bin/clang-18"
"-cc1"
"-triple"
"aarch64-unknown-linux-android21"
"-emit-obj"
"-mrelax-all"
"-dumpdir"
"g-"
"-disable-free"
"-clear-ast-before-backend"
"-disable-llvm-verifier"
"-discard-value-names"
"-main-file-name"
"g.cpp"
"-mrelocation-model"
"pic"
"-pic-level"
"2"
"-pic-is-pie"
"-mframe-pointer=non-leaf"
"-ffp-contract=on"
"-fno-rounding-math"
"-mconstructor-aliases"
"-funwind-tables=2"
"-target-cpu"
"generic"
"-target-feature"
"+neon"
"-target-feature"
"+v8a"
"-target-feature"
"+fix-cortex-a53-835769"
"-target-abi"
"aapcs"
"-debugger-tuning=gdb"
"-fdebug-compilation-dir=@CWD@"
"-fcoverage-compilation-dir=@CWD@"
"-resource-dir"
"@ROOT@/lib/clang/18"
"-internal-isystem"
"@ROOT@/sysroot/usr/include/c++/v1"
"-internal-isystem"
"@ROOT@/lib/clang/18/include"
"-internal-isystem"
"@ROOT@/sysroot/usr/local/include"
"-internal-externc-isystem"
"@ROOT@/sysroot/usr/include/aarch64-linux-android"
"-internal-externc-isystem"
"@ROOT@/sysroot/include"
"-internal-externc-isystem"
"@ROOT@/sysroot/usr/include"
"-fdeprecated-macro"
"-ferror-limit"
"19"
"-femulated-tls"
"-fno-signed-char"
"-fgnuc-version=4.2.1"
"-fcxx-exceptions"
"-fexceptions"
"-target-feature"
"+outline-atomics"
"-target-feature"
"-fmv"
"-D__GCC_HAVE_DWARF2_CFI_ASM=1"
"-o"
"@TMPO@"
"-x"
"c++"
"g.cpp"
"@ROOT@/bin/ld.lld"
"-EL"
"--fix-cortex-a53-843419"
"-z"
"now"
"-z"
"relro"
"-z"
"max-page-size=4096"
"--hash-style=both"
"--eh-frame-hdr"
"-m"
"aarch64linux"
"-pie"
"-dynamic-linker"
"/system/bin/linker64"
"-o"
"g"
"@ROOT@/sysroot/usr/lib/aarch64-linux-android/21/crtbegin_dynamic.o"
"-L@ROOT@/lib/clang/18/lib/linux/aarch64"
"-L@ROOT@/sysroot/usr/lib/aarch64-linux-android/21"
"-L@ROOT@/sysroot/usr/lib/aarch64-linux-android"
"-L@ROOT@/sysroot/usr/lib"
"@TMPO@"
"-lc++"
"-lm"
"@ROOT@/lib/clang/18/lib/linux/libclang_rt.builtins-aarch64-android.a"
"-l:libunwind.a"
"-ldl"
"-lc"
"@ROOT@/lib/clang/18/lib/linux/libclang_rt.builtins-aarch64-android.a"
"-l:libunwind.a"
"-ldl"
"@ROOT@/sysroot/usr/lib/aarch64-linux-android/21/crtend_android.o"
GOLDEN_LINK_TOKENS_END
