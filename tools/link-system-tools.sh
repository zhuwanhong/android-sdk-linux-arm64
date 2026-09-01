#!/usr/bin/env bash
# 把**发行版已经有的**那几样接进 SDK/NDK，然后逐个验。
#
# 起因是判据被用错了两次：`cmake` 和 `lldb` 都曾被列进「只能我们编」，
# 而 `apt install` 一条命令就有。把剩下的逐个查过之后，「只能我们编」那一栏
# 只剩 simpleperf —— 其余的活不是「编」，是**「接」和「验」**：
# 把系统那份摆到 NDK/SDK 期望的路径和目录名下，再确认工具链真认它。
#
# 判据分四类（见 README 第三节末尾）：
#   AOSP 独有                aapt2 adb aidl dexdump …   只能我们编
#   上游项目 + AOSP 封装      mke2fs make_f2fs（链 libsparse）  也只能我们编
#   标准开源，发行版有 ARM 版  cmake ninja lldb clangd glslc     ← **这个脚本管这些**
#   纯 Java／跟架构无关        cmdline-tools platforms/          官方那份就行
#
# ---------------------------------------------------------------------------
# 验证不是 `--version` 就算完（第五节第 2 条）。每一组都真做一件事：
#
#   cmake + ninja  拿 NDK 的 android.toolchain.cmake 真交叉编一个 arm64-v8a 的 .so
#   glslc          编一个 GLSL 成 SPIR-V，再用 spirv-val 过官方校验器
#   lldb           让它真读一个 Android 的 .so（认不认那个 ELF）
#   clang-tidy     对一个真源文件跑一遍
#
# 前两组在 x86_64 上先验过原型：
#   cmake 3.28.3 + ninja 1.11.1 + NDK r27b 的 toolchain 文件 -> 编出 arm64-v8a 的 .so
#   系统 glslc(2023.8) vs NDK 自带 glslc(v2022.3)：SPIR-V **反汇编逐行相同**，
#     唯一差异是头里那个 generator 版本号（10 vs 11），两边都过 spirv-val
#
# ---------------------------------------------------------------------------
# 用法：
#   tools/link-system-tools.sh [--check] [SDK 路径]
#     --check   只报告，一个文件都不动
#
# 只创建软链，**不覆盖已经存在的东西**——碰上已有的就报告冲突，让人自己决定。

set -uo pipefail

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
_rev=$(git -C "$REPO" log -1 --format='%h %ad' --date=short -- "${BASH_SOURCE[0]}" 2>/dev/null)
printf '  \033[2m%s @ %s\033[0m\n' "$(basename "${BASH_SOURCE[0]}")" "${_rev:-（不在 git 里）}"

CHECK_ONLY=0
case "${1:-}" in --check) CHECK_ONLY=1; shift ;; esac

SDK="${1:-${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}}"
[ -n "$SDK" ] && [ -d "$SDK" ] || die "找不到 SDK。设 ANDROID_HOME，或者传路径过来。"
SDK=$(cd "$SDK" && pwd)
NDK="${ANDROID_NDK_HOME:-}"
[ -n "$NDK" ] || { for d in "$SDK"/ndk/*/; do NDK="${d%/}"; done; }
[ -n "$NDK" ] && [ -d "$NDK" ] || die "找不到 NDK（$SDK/ndk/ 下没有）。"
TC="$NDK/toolchains/llvm/prebuilt/linux-aarch64"

step "对谁动手"
note "SDK $SDK"
note "NDK $NDK"
[ "$CHECK_ONLY" = 1 ] && note "（--check：只看，不动文件）"

HOST=$(uname -m)
[ "$HOST" = aarch64 ] || [ "$HOST" = arm64 ] || \
  warn "这台是 $HOST，不是 aarch64。软链能建，但**验证那几步做不了**。"

# ---------------------------------------------------------------------------
# 摆一个软链，带自检。$1=源（系统那份） $2=目标路径
put() {
  local src=$1 dst=$2 name; name=$(basename "$dst")
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    local cur; cur=$(readlink -f "$dst" 2>/dev/null)
    if [ "$cur" = "$(readlink -f "$src")" ]; then note "$name 已经指着系统那份了"; return 0; fi
    warn "$name 那个位置已经有东西了（$dst -> ${cur:-断链}），**没动它**"
    note "  要换的话自己先挪开。这个脚本不覆盖已有的文件。"
    return 1
  fi
  [ "$CHECK_ONLY" = 1 ] && { note "会建：$dst -> $src"; return 0; }
  mkdir -p "$(dirname "$dst")" || return 1
  ln -s "$src" "$dst" || { warn "建不了 $dst"; return 1; }
  note "建了 $dst -> $src"
}

need() {  # $1=命令名 $2=apt 包名；找不到就报怎么装
  local c; c=$(command -v "$1" 2>/dev/null)
  [ -n "$c" ] && { printf '%s' "$c"; return 0; }
  warn "系统里没有 $1 —— 这一组跳过。装：sudo apt install -y $2"
  return 1
}

n_ok=0; n_skip=0; n_fail=0

# ===========================================================================
step "一、cmake + ninja"
# AGP 找 $ANDROID_HOME/cmake/<版本>/bin/{cmake,ninja} —— **目录名就是版本号**。
# 官方发过 17 个版本（3.6.4111459 一直到 4.1.2），项目要哪个由它自己的
# build.gradle 说了算，所以这里用**系统 cmake 的真实版本**做目录名，不冒充。
if CM=$(need cmake cmake) && NJ=$(need ninja ninja-build); then
  CMV=$("$CM" --version | sed -n '1s/.*version //p')
  note "系统 cmake $CMV，ninja $("$NJ" --version)"
  DST="$SDK/cmake/$CMV"
  put "$CM" "$DST/bin/cmake"; put "$NJ" "$DST/bin/ninja"
  if [ "$CHECK_ONLY" = 1 ]; then
    n_skip=$((n_skip+1))
  else
    # 验：拿 NDK 的 toolchain 文件真交叉编一个 .so。这条在 x86_64 上验过原型。
    T=$(mktemp -d); printf 'int f(void){return 42;}\n' > "$T/x.c"
    printf 'cmake_minimum_required(VERSION 3.10)\nproject(x C)\nadd_library(x SHARED x.c)\n' > "$T/CMakeLists.txt"
    if "$DST/bin/cmake" -S "$T" -B "$T/b" -G Ninja \
         -DCMAKE_MAKE_PROGRAM="$DST/bin/ninja" \
         -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
         -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-24 >"$T/log" 2>&1 \
       && "$DST/bin/cmake" --build "$T/b" >>"$T/log" 2>&1 \
       && [ -f "$T/b/libx.so" ]; then
      case "$(file -b "$T/b/libx.so")" in
        *"ARM aarch64"*) ok "系统 cmake 驱动 NDK 编出了 arm64-v8a 的 .so"; n_ok=$((n_ok+1)) ;;
        *) warn "编出来了但不是 aarch64：$(file -b "$T/b/libx.so")"; n_fail=$((n_fail+1)) ;;
      esac
    else
      warn "系统 cmake 驱动不了 NDK"; tail -5 "$T/log" | sed 's/^/      /'; n_fail=$((n_fail+1))
    fi
    rm -rf "$T"
  fi
  # ------------------------------------------------------------------------
  # **AGP 按目录名挑，不按二进制自报的版本号挑。** 这条是实测出来的，
  # 不是猜的：把系统的 cmake 3.28.3 摆成 cmake/3.22.1/，local.properties 里
  # **不写 cmake.dir**，AGP 照样用它，CMakeCache 里留下的是
  #     CMAKE_MAKE_PROGRAM = <SDK>/cmake/3.22.1/bin/ninja
  #     CMAKE_CACHE_MINOR_VERSION = 28
  # ——它从「3.22.1」那个目录取了 ninja，而真正跑的是 3.28。
  #
  # 所以再补一个别名目录，下游就**不用写 cmake.dir** 了。
  # 用目录软链而不是拷贝：`ls -l` 一眼就能看出 3.22.1 是谁的别名，不装成真的。
  # 3.22.1 是**当前** AGP 的默认值；换个 AGP 可能要别的号，那就照样再软链一个。
  AGP_DEFAULT=3.22.1
  if [ "$CMV" != "$AGP_DEFAULT" ]; then
    ALIAS="$SDK/cmake/$AGP_DEFAULT"
    if [ -e "$ALIAS" ] || [ -L "$ALIAS" ]; then
      cur=$(readlink "$ALIAS" 2>/dev/null)
      if [ "$cur" = "$CMV" ]; then
        note "$AGP_DEFAULT 已经是 $CMV 的别名了"
      else
        warn "$ALIAS 已经有东西了（$( [ -L "$ALIAS" ] && echo "软链 -> $cur" || echo 真目录 )），**没动它**"
        note "  那份多半是 AGP 自己下的 x86_64 版。要换成别名得先自己挪开。"
      fi
    elif [ "$CHECK_ONLY" = 1 ]; then
      note "会建：$ALIAS -> $CMV（AGP 默认要 $AGP_DEFAULT，有了它就不用写 cmake.dir）"
    else
      ln -s "$CMV" "$ALIAS" && ok "别名 cmake/$AGP_DEFAULT -> $CMV（AGP 默认要这个号）" \
        || warn "建不了别名 $ALIAS"
    fi
  fi
  note "AGP 要别的版本号时（上面那个别名不管用了）："
  note "  · 项目的 android/local.properties 里写 cmake.dir=$DST"
  note "  · 或者照样再软链一个：ln -s $CMV $SDK/cmake/<那个版本>"
else n_skip=$((n_skip+1)); fi

# ===========================================================================
step "二、glslc + spirv-*（shader-tools）"
# 官方 NDK 把它们放在 shader-tools/<host tag>/。我们的包没带（没有 aarch64 版），
# 但发行版有 —— 而且**产出等价**：x86_64 上比过，SPIR-V 反汇编逐行相同，
# 唯一差异是头里的 generator 版本号。
if GL=$(need glslc glslc); then
  DST="$NDK/shader-tools/linux-aarch64"
  put "$GL" "$DST/glslc"
  for t in spirv-as spirv-dis spirv-val spirv-opt spirv-link spirv-cfg spirv-reduce; do
    p=$(command -v "$t" 2>/dev/null) && put "$p" "$DST/$t"
  done
  command -v spirv-val >/dev/null || warn "没有 spirv-val（sudo apt install -y spirv-tools），下面只能验编译不能验校验"
  if [ "$CHECK_ONLY" = 1 ]; then
    n_skip=$((n_skip+1))
  else
    T=$(mktemp -d)
    printf '#version 450\nlayout(location=0) out vec4 c;\nlayout(location=0) in vec2 uv;\nvoid main(){ c = vec4(uv, 0.5, 1.0); }\n' > "$T/t.frag"
    if "$DST/glslc" -O "$T/t.frag" -o "$T/t.spv" 2>"$T/log" && [ -s "$T/t.spv" ]; then
      if [ -x "$DST/spirv-val" ] && ! "$DST/spirv-val" "$T/t.spv" >>"$T/log" 2>&1; then
        warn "编出来了，但过不了 spirv-val"; n_fail=$((n_fail+1))
      else
        ok "glslc 编出 SPIR-V（$(stat -c%s "$T/t.spv") 字节）$([ -x "$DST/spirv-val" ] && echo '，spirv-val 通过')"
        n_ok=$((n_ok+1))
      fi
    else
      warn "glslc 编不出来"; tail -3 "$T/log" | sed 's/^/      /'; n_fail=$((n_fail+1))
    fi
    rm -rf "$T"
  fi
else n_skip=$((n_skip+1)); fi

# ===========================================================================
step "三、lldb（host 端）"
# **设备端那一半本来就在包里**：lldb-server 住在
# lib/clang/<ver>/lib/linux/<arch>/，是 Android 目标二进制，跟 host 架构无关。
# 缺的只有 host 端。ndk-gdb 按 toolchain/bin/{lldb.sh,lldb,…} 这个顺序找。
srv=$(ls "$TC"/lib/clang/*/lib/linux/aarch64/lldb-server 2>/dev/null | head -1)
[ -n "$srv" ] && note "设备端的 lldb-server 在：${srv#$NDK/}" || warn "包里没找到 lldb-server —— 那 host 端接进来也调不了设备"
if LL=$(need lldb lldb); then
  put "$LL" "$TC/bin/lldb"
  if [ "$CHECK_ONLY" = 1 ]; then n_skip=$((n_skip+1))
  else
    # 验：让它真读一个 Android 的 .so（认不认那个 ELF），不是只看 --version
    so=$(ls "$TC"/sysroot/usr/lib/aarch64-linux-android/*/libc.so 2>/dev/null | head -1)
    if [ -z "$so" ]; then warn "sysroot 里没找到 aarch64 的 libc.so，这条验不了"; n_skip=$((n_skip+1))
    elif "$TC/bin/lldb" -b -o "target create --arch aarch64 $so" -o quit >/dev/null 2>&1; then
      ok "系统 lldb 读得懂 Android 的 aarch64 ELF（$("$LL" --version 2>&1 | head -1)）"

      # ------------------------------------------------------------------
      # **再往前走一步：真调一个进程。**
      # 「读得懂 ELF」离「能调试」还差得远。设备调试那条路是
      #     host lldb  --(gdb-remote 协议)-->  设备上的 lldb-server
      # 而 **lldb-server 是 Android 目标二进制、静态 bionic，在 ARM64 Linux 上
      # 跑得起来**（整个项目就建立在这个事实上）。所以除了「adb 传输」和「真设备
      # 硬件」这两环，其余可以在本机走一遍环回。
      #
      # 这不等于验了连设备 —— docs/LESSONS.md 那张表里那行还留着。但它把未知面缩到
      # 只剩那两环，而不是整条链路。
      srv2=$(ls "$TC"/lib/clang/*/lib/linux/aarch64/lldb-server 2>/dev/null | head -1)
      tgt=""
      for c in "$SDK"/build-tools/*/aapt2; do
        [ -x "$c" ] && "$c" version >/dev/null 2>&1 && { tgt="$c"; break; }
      done
      if [ -z "$srv2" ] || [ -z "$tgt" ]; then
        note "环回调试那步跳过（缺 lldb-server 或没有能跑的 aapt2 当靶子）—— **没验**"
      elif ! "$srv2" version >/dev/null 2>&1; then
        # 「文件在」不等于「能跑」。这台跑不了就明说，别当验过。
        note "包里的 lldb-server 在这台上跑不起来，环回调试那步**没验**"
      else
        port=$(( 20000 + RANDOM % 20000 ))
        lg=$(mktemp); cl=$(mktemp)
        "$srv2" gdbserver "127.0.0.1:$port" -- "$tgt" version >"$lg" 2>&1 &
        srv_pid=$!
        for _ in 1 2 3 4 5 6 7 8 9 10; do
          _p=$(ss -ltn 2>/dev/null); case "$_p" in *":$port"*) break ;; esac
          sleep 0.3 2>/dev/null || true
        done
        timeout 60 "$LL" -b -o "gdb-remote 127.0.0.1:$port" \
          -o "register read pc" -o "continue" -o "quit" >"$cl" 2>&1
        kill "$srv_pid" 2>/dev/null; wait "$srv_pid" 2>/dev/null
        # **判据是两条都要**：停得下来（协议通了），而且能跑到正常退出
        # （不是连上就断）。只判一条会把「连上了但立刻崩」判成通过。
        if grep -q 'stop reason' "$cl" && grep -q 'exited with status = 0' "$cl"; then
          ok "环回调试通了：lldb 连上 lldb-server，停住、读了 pc、继续到正常退出"
          note "**这不是连设备** —— 少的是 adb 传输和真机，其余这条路走过了。"
        else
          warn "环回调试没通（不影响上面那条结论，但连设备多半也不行）："
          sed 's/^/      /' "$cl" | tail -6 >&2
        fi
        rm -f "$lg" "$cl"
      fi
      n_ok=$((n_ok+1))
    else
      warn "系统 lldb 读不了 Android 的 .so"; n_fail=$((n_fail+1))
    fi
  fi
else n_skip=$((n_skip+1)); fi

# ===========================================================================
step "四、clang-tidy + clangd"
CT=$(command -v clang-tidy 2>/dev/null || ls /usr/bin/clang-tidy-* 2>/dev/null | sort -V | tail -1)
CD=$(command -v clangd     2>/dev/null || ls /usr/bin/clangd-*     2>/dev/null | sort -V | tail -1)
if [ -n "$CT" ]; then
  put "$CT" "$TC/bin/clang-tidy"; [ -n "$CD" ] && put "$CD" "$TC/bin/clangd"
  if [ "$CHECK_ONLY" = 1 ]; then n_skip=$((n_skip+1))
  else
    # 判据得挑仔细：clang-tidy 对有毛病的代码**本来就返回非零**，
    # 拿退出码当判据会把「正常工作」判成失败；而拿「log 里有没有 error」当判据，
    # 又会把「clang-tidy 自己跑不起来」也判成成功 —— 那正是这个仓库反复栽的
    # 「失败和成功共用一个出口」。
    # 所以：用一段**干净的、#include 了 Android 头文件**的代码。真正要验的是
    # 它认不认 NDK 的 sysroot（找不到头文件会报 'file not found'），
    # 判据是**输出里没有 error:**。
    T=$(mktemp -d)
    printf '#include <android/log.h>\nint f(void){ return __ANDROID_API__; }\n' > "$T/x.c"
    # **别加 --checks=-***。本意是「关掉检查、只验解析」，实际 clang-tidy 会
    # 报 `Error: no checks enabled.` 打印 usage 直接退出 —— 文件根本没编译。
    # 那次它还正好躲过了下面的 grep（usage 里是大写 Error，这里找的是 clang
    # 诊断格式的小写 error:），两个巧合叠起来，整步验证变成 no-op 却报绿。
    # 所以下面多一条：**先确认它没打印 usage**，再看诊断。
    "$TC/bin/clang-tidy" "$T/x.c" -- -target aarch64-linux-android24 \
      --sysroot="$TC/sysroot" >"$T/log" 2>&1
    rc=$?
    if [ "$rc" -ge 126 ]; then
      warn "clang-tidy 起不来（退出码 $rc）"; n_fail=$((n_fail+1))
    elif grep -q '^USAGE:' "$T/log"; then
      warn "clang-tidy 打印了 usage —— 参数不对，它根本没编那个文件。"
      head -2 "$T/log" | sed 's/^/      /'; n_fail=$((n_fail+1))
    elif grep -q 'error:' "$T/log"; then
      warn "clang-tidy 跑了，但读不了 NDK 的 sysroot："
      grep 'error:' "$T/log" | head -3 | sed 's/^/      /'; n_fail=$((n_fail+1))
    else
      ok "clang-tidy 认得 NDK 的 sysroot，解析 Android 头文件没报错（$("$CT" --version 2>&1 | sed -n 's/.*version //p' | head -1)）"
      n_ok=$((n_ok+1))
    fi
    rm -rf "$T"
  fi
else warn "系统里没有 clang-tidy —— 跳过。装：sudo apt install -y clang-tidy clangd"; n_skip=$((n_skip+1)); fi

# ===========================================================================
# ---------------------------------------------------------------------------
# **在 SDK 里留一份自述。**
#
# 这个脚本往别人的 SDK 里塞软链，而软链是**看不见的改动**：将来有人站在
# $SDK/cmake/3.22.1 里敲 `cmake --version`，看到的是 3.28.3，他不会去翻我们
# 仓库的 README —— 他会站在那个目录里发懵。
# 所以记录要放在**他将来正站着的地方**，不是只放在我们的文档里。
#
# 文件名跟包里那份 PROVENANCE.txt 错开：那份讲「这个包是怎么来的」，
# 这份讲「这个 SDK 被这个脚本动过什么」，而且这个脚本也可能被用在**不是**
# 我们打的 SDK 上。
write_manifest() {
  local f="$SDK/PROVENANCE-system-tools.txt"
  [ "$CHECK_ONLY" = 1 ] && { note "会写：$f"; return 0; }
  {
    echo "这个 SDK 里有一些软链指向**系统装的工具**，是 tools/link-system-tools.sh 建的。"
    echo
    echo "写于     $(date -u '+%Y-%m-%d %H:%M UTC')"
    echo "在哪台   $(uname -m) $(uname -s)，$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-未知发行版}" )"
    echo "脚本     link-system-tools.sh @ ${_rev:-（不在 git 里）}"
    echo "来源     https://github.com/zhuwanhong/android-sdk-linux-arm64"
    echo
    echo "为什么有这些软链：Google 的 SDK 仓库里 linux+aarch64 的包是 0 个，"
    echo "cmake / ninja / lldb / clangd / glslc 这些**标准开源工具发行版自己就有**"
    echo "ARM 版，所以不重编，接进来用。"
    echo
    echo "== 现在有哪些 =="
    local any=0
    for l in "$SDK"/cmake/*/bin/cmake "$SDK"/cmake/*/bin/ninja \
             "$NDK"/shader-tools/*/* "$TC"/bin/lldb "$TC"/bin/clang-tidy "$TC"/bin/clangd; do
      [ -L "$l" ] || continue
      any=1
      printf '  %s\n      -> %s\n' "${l#$SDK/}" "$(readlink "$l")"
    done
    [ "$any" = 1 ] || echo "  （一个都没有）"
    echo
    for d in "$SDK"/cmake/*; do
      [ -L "$d" ] || continue
      echo "== cmake/$(basename "$d") 是个别名，不是真的那个版本 =="
      echo "  $(basename "$d") -> $(readlink "$d")，里面的 cmake 真实版本是"
      echo "  $("$d/bin/cmake" --version 2>/dev/null | head -1)。"
      echo
      echo "  **这不是笔误。** AGP 挑 cmake 是按**目录名**挑的，不看二进制自报的"
      echo "  版本号 —— 实测过：目录叫 3.22.1、里面是 3.28.3，local.properties 里"
      echo "  一个字都不写，构建照样过，CMakeCache 里留下的是"
      echo "      CMAKE_MAKE_PROGRAM = <SDK>/cmake/$(basename "$d")/bin/ninja"
      echo "      CMAKE_CACHE_MINOR_VERSION = $("$d/bin/cmake" --version 2>/dev/null | sed -n '1s/.*version [0-9]*\.\([0-9]*\).*/\1/p')"
      echo "  有了这个别名，下游就不必在 local.properties 里写 cmake.dir。"
      echo
    done
    echo "== 想撤掉 =="
    echo "  这些**全都是软链**，删掉就干净了，不会动到系统里那份，"
    echo "  也不会动到包自带的那些（NDK 里 prebuilt/linux-x86_64 -> linux-aarch64"
    echo "  之类指向包内的软链）—— 下面这两条实测过，只删走指向 /usr 的那批："
    echo "    find \"$SDK\" -type l -lname '/usr/*' -delete"
    echo "    # cmake 的别名目录是目录软链，另删："
    echo "    find \"$SDK/cmake\" -maxdepth 1 -type l -delete"
    echo
    echo "== 换台机器 =="
    echo "  别拷这些软链，重跑一次 link-system-tools.sh —— 系统工具的版本和路径"
    echo "  换台机器就变了。"
  } > "$f" || { warn "写不了 $f"; return 1; }
  ok "$f"
}
step "在 SDK 里留一份自述"
write_manifest

step "结果"
note "验过并通过：$n_ok    跳过：$n_skip    没通过：$n_fail"
[ "$n_fail" = 0 ] || die "有 $n_fail 组没通过 —— 上面写着哪一组、为什么。"
[ "$n_ok" -gt 0 ] || warn "一组都没真验过（--check，或者系统里这些都没装）。"
note ""
note "这些是**发行版的**工具，不是我们编的，也不在分发包里。"
note "换台机器要重跑一次这个脚本。理由和判据见 README 第三节末尾。"
