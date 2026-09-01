#!/usr/bin/env bash
# 自己编一份 hermesc —— React Native 打 release 包时把 JS 编成 Hermes 字节码
# （.hbc）的那个编译器。
#
# **为什么它属于这个项目**：npm 上的 hermes-compiler 包一共只发三个二进制 ——
# win64 / osx / linux64（x86_64）。**没有 ARM Linux 版。** 跟这个项目要解决的是
# 同一件事：官方只发 x86_64，ARM64 Linux 上的人卡在这里。
# 而且 RN 的 Gradle 插件自己就把这条钉死了（@react-native/gradle-plugin 的
# PathUtils.kt:189）：
#
#     internal fun getHermesOSBin(): String {
#       if (Os.isWindows()) return "win64-bin"
#       if (Os.isMac()) return "osx-bin"
#       if (Os.isLinuxAmd64()) return "linux64-bin"
#       error("OS not recognized. Please set project.react.hermesCommand ...")
#     }
#
# ARM64 Linux 上它直接报错，**而且错误信息就是让你设 hermesCommand**。
# 所以接进去不用打任何补丁，见本文件末尾打印的三条路。
#
# ---------------------------------------------------------------------------
# **跟其余 14 个工具都不同的一点，先说清楚**：hermesc 是 **host 工具**
# （跑在打包机上，吃 .js 吐 .hbc），所以它是 **glibc 构建**，
# 跟 tools/build-llvm.sh 同类，**不能套 tools/build-common.sh 那个
# 静态 bionic 骨架** —— 那套是拿 NDK 交叉编 Android 目标二进制的。
# 这跟 simpleperf 那次踩的 LLVM 是同一个形状：
# 「我们编过这个东西」和「我们有这个 ABI 的这个东西」是两回事。
#
# ---------------------------------------------------------------------------
# **版本不能猜。** Hermes 的字节码格式跟 RN 版本绑死，编错版本出来的 .hbc
# 手机上加载不了。对应关系是明写在 RN 包里的，可机读：
#
#     node_modules/react-native/sdks/.hermesv1version    -> hermes-v250829098.0.17
#     node_modules/react-native/sdks/hermes-engine/version.properties
#                                        -> HERMES_VERSION_NAME=250829098.0.17
#
# 这个脚本默认就编上面那个 tag；换 RN 版本就用 HERMES_TAG= 指过去，
# 或者传 --from-rn <RN 工程目录> 让它自己从那个工程读。
#
# 用法：
#   tools/build-hermesc.sh [--fetch|--build|--verify]
#   HERMES_TAG=hermes-vX.Y.Z tools/build-hermesc.sh
#   WORK=/path tools/build-hermesc.sh

set -uo pipefail

die()  { printf '\n  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1" >&2; }

# file(1) 是硬依赖：下面拿 `case "$(file -b …)" in *"ARM aarch64"*)` 判架构。
# file 一缺，命令替换是空串，会死在「不是 aarch64：」—— 死是对的，但指错了方向。
command -v file >/dev/null || die "要 file(1)：sudo apt install -y file
    这个脚本靠它认二进制架构。"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO/tools/repro.sh"   # 可复现打包：repro_init / repro_tar
repro_init
for f in "$0"; do
  _rev=$(git -C "$REPO" log -1 --format='%h %ad' --date=short -- "$f" 2>/dev/null)
  printf '  \033[2m%s @ %s\033[0m\n' "$(basename "$f")" "${_rev:-（不在 git 里）}"
done

WORK="${WORK:-$REPO/work}"
SRC="$WORK/hermes"
BUILD="$WORK/hermes-build"
OUT="$WORK/out/hermesc"

# RN 0.87.1 pin 的那个。换 RN 版本请一并改这里，或者用环境变量覆盖。
HERMES_TAG="${HERMES_TAG:-hermes-v250829098.0.17}"
UPSTREAM=https://github.com/facebook/hermes

DO_FETCH=1 DO_BUILD=1 DO_VERIFY=1
case "${1:-}" in
  --fetch)  DO_BUILD=0; DO_VERIFY=0 ;;
  --build)  DO_FETCH=0; DO_VERIFY=0 ;;
  --verify) DO_FETCH=0; DO_BUILD=0 ;;
  "") ;;
  *) die "不认识的参数：$1（只有 --fetch / --build / --verify）" ;;
esac

if [ "$DO_FETCH" = 1 ]; then
  step "取 Hermes 源码（$HERMES_TAG）"
  command -v git >/dev/null || die "没有 git"
  if [ -f "$SRC/CMakeLists.txt" ]; then
    have=$(git -C "$SRC" describe --tags --exact-match 2>/dev/null)
    if [ "$have" = "$HERMES_TAG" ]; then
      note "$SRC 已经是 $HERMES_TAG，跳过"
    else
      die "$SRC 已存在，但它是 ${have:-（不是某个 tag）}，不是 $HERMES_TAG。
    自己挪开或者删掉再跑 —— **不自动删别人的源码树**。"
    fi
  else
    rm -rf "$SRC"
    git clone --depth 1 --branch "$HERMES_TAG" -c advice.detachedHead=false \
      "$UPSTREAM" "$SRC" || die "clone $UPSTREAM ($HERMES_TAG) 失败"
  fi
  [ -f "$SRC/CMakeLists.txt" ] || die "取下来了但没有 CMakeLists.txt —— tag 对吗？"
  ok "$SRC（$(du -sh "$SRC" 2>/dev/null | cut -f1)，$HERMES_TAG）"
fi

if [ "$DO_BUILD" = 1 ]; then
  step "编 hermesc"
  [ -f "$SRC/CMakeLists.txt" ] || die "源码不在，先跑 --fetch"
  # **核对源码树到底是哪个 tag。** --fetch 会核，但 --build 单独跑时原来不核，
  # 于是「源码是 .0.16、HERMES_TAG 默认成 .0.17」时会编出一个**贴错标签的包**。
  # 字节码格式跟 RN 版本绑死，贴错标签比编不出来更糟 —— 它会被人装上去。
  have=$(git -C "$SRC" describe --tags --exact-match 2>/dev/null)
  [ "$have" = "$HERMES_TAG" ] || die "源码树是 ${have:-（不在某个 tag 上）}，而 HERMES_TAG=$HERMES_TAG。
    这两个必须一致 —— 否则包名和里面的东西对不上。
    要么 HERMES_TAG=$have 重跑，要么先 --fetch 换成 $HERMES_TAG 那棵树。"
  command -v cmake >/dev/null || die "没有 cmake：sudo apt install -y cmake"
  command -v ninja >/dev/null || die "没有 ninja：sudo apt install -y ninja-build"
  command -v python3 >/dev/null || die "没有 python3（Hermes 的构建要它）"
  note "$(cmake --version | head -1)，ninja $(ninja --version)，$(nproc) 核"
  cmake -S "$SRC" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    || die "cmake 配置失败"
  ninja -C "$BUILD" hermesc || die "编译失败"
  bin="$BUILD/bin/hermesc"
  [ -x "$bin" ] || die "编完了但 $bin 不在"
  mkdir -p "$(dirname "$OUT")"
  cp "$bin" "$OUT"
  ok "产物 $OUT（$(stat -c%s "$OUT") 字节）"

  # ------------------------------------------------------------------ 打包
  # **摆成 RN 官方那两个开关直接认的样子**，别让下游自己去猜路径：
  #   build/bin/hermesc   —— REACT_NATIVE_OVERRIDE_HERMES_DIR 指向解出来的那个
  #                          目录就能用（插件去找 <它>/build/bin/hermesc）
  #   同一个文件           —— 也可以直接被 react { hermesCommand } 指
  #
  # 为什么要单独一个包、不塞进 SDK 那两个 tar.gz：**hermesc 不是 Android SDK 的
  # 组件**，它是 React Native 那条链上的。SDK 包解到 $ANDROID_HOME，
  # 而这个不该出现在 $ANDROID_HOME 里。
  VER="${HERMES_TAG#hermes-v}"
  PKGDIR="$WORK/hermesc-$VER-linux-aarch64"
  rm -rf "$PKGDIR"; mkdir -p "$PKGDIR/build/bin"
  cp "$OUT" "$PKGDIR/build/bin/hermesc"
  {
    echo "hermesc for linux-aarch64"
    echo
    echo "上游       $UPSTREAM"
    echo "tag        $HERMES_TAG"
    # 用 $REPRO_STAMP 而不是实时时间：包要可复现。这一行原先是
    # date -u '+%Y-%m-%d %H:%M UTC'，分钟精度 —— 同一分钟内重打看着一致，
    # 跨了分钟就变，实测就是这么露的馅。
    echo "编译于     $REPRO_STAMP UTC，$(uname -m) $(uname -s)（SOURCE_DATE_EPOCH=$REPRO_EPOCH）"
    echo "字节码版本 $("$OUT" -version 2>&1 | grep -oiE 'bytecode version[: ]+[0-9]+' | grep -oE '[0-9]+$')"
    echo
    echo "为什么有这个包：npm 的 hermes-compiler 只发 win64 / osx / linux64(x86_64)"
    echo "三个二进制，没有 ARM Linux 版。这一份是照同一个 tag 的源码自己编的。"
    echo
    echo "怎么用（两条，都是 RN 官方的开关，npm install 冲不掉）："
    echo "  1. android/app/build.gradle 的 react { } 里："
    echo "       hermesCommand = \"<解压位置>/build/bin/hermesc\""
    echo "     **优先级最高**。注意 expo prebuild 会重写 build.gradle，"
    echo "     所以要写进你自己的 prebuild 后处理脚本里。"
    echo "  2. 环境变量 REACT_NATIVE_OVERRIDE_HERMES_DIR=<解压位置>"
    echo "     插件会去找 <它>/build/bin/hermesc —— 本包的目录结构就是照这个摆的。"
    echo "     **但只在 build.gradle 没设 hermesCommand 时才生效**（见 RN 插件"
    echo "     @react-native/gradle-plugin 的 utils/PathUtils.kt）。"
    echo
    echo "版本必须跟工程对上：看 node_modules/react-native/sdks/.hermesv1version，"
    echo "它写的就是上面那个 tag。对不上就换 HERMES_TAG= 重编。"
  } > "$PKGDIR/PROVENANCE.txt"
  TAR="$WORK/hermesc-$VER-linux-aarch64.tar.gz"
  rm -f "$TAR"
  repro_tar "$WORK" "$TAR" "hermesc-$VER-linux-aarch64" || die "打包失败"
  ok "$TAR（$(du -h "$TAR" | cut -f1)）"
  note "解开就能用："
  note "  tar -xzf $TAR -C /要放的地方"
  note "  然后 hermesCommand = \"/要放的地方/hermesc-$VER-linux-aarch64/build/bin/hermesc\""
fi

if [ "$DO_VERIFY" = 1 ]; then
  step "验自己编的这个 hermesc"
  [ -f "$OUT" ] || die "$OUT 不在，先编出来"
  f=$(file -b "$OUT")
  note "$f"
  case "$f" in
    *"ARM aarch64"*) ;;
    *) die "不是 aarch64：$f" ;;
  esac
  case "$f" in
    *"interpreter /lib"*|*"dynamically linked"*) ;;
    *) warn "看着不像动态链的 glibc 二进制，留意一下：$f" ;;
  esac
  ok "是 aarch64 的 host 二进制，$(stat -c%s "$OUT") 字节"

  T="$WORK/verify-hermesc"; rm -rf "$T"; mkdir -p "$T"

  step "1/4  真编一段 JS 成字节码"
  # 判据不是「退出码 0」也不是「有输出文件」——要看**产物真是 Hermes 字节码**。
  cat > "$T/a.js" <<'JS'
function add(a, b) { return a + b; }
print(add(20, 22));
JS
  "$OUT" -emit-binary -out "$T/a.hbc" "$T/a.js" >"$T/1.log" 2>&1 \
    || { sed 's/^/      /' "$T/1.log" >&2; die "hermesc 编不出来"; }
  [ -s "$T/a.hbc" ] || die "退出码是 0，但 $T/a.hbc 是空的"
  # HBC 文件头有个固定魔数。**直接读文件，不走管道**（管道 + pipefail 会把
  # 命中判成失败，这个仓库栽过）。
  magic=$(head -c 8 "$T/a.hbc" | od -An -tx1 | tr -d ' \n')
  case "$magic" in
    c61fbc03c103191f) ok "产出 $(stat -c%s "$T/a.hbc") 字节，文件头魔数对（$magic）" ;;
    *) die "产物的头 8 字节是 $magic，不是 Hermes 字节码的魔数
    （HBC 的魔数是 c61fbc03c103191f，见 hermes 的 BytecodeFileFormat.h）" ;;
  esac

  step "2/4  字节码版本号必须跟这个 tag 对得上"
  # **这条是这个工具最要紧的一条**：编错版本的 .hbc 手机上加载不了，
  # 而那时候错误出现在别人的设备上，不在这里。
  v=$("$OUT" -version 2>&1 | grep -oiE 'bytecode version[: ]+[0-9]+' | grep -oE '[0-9]+$')
  [ -n "$v" ] || { "$OUT" -version 2>&1 | sed 's/^/      /' >&2; die "读不出 hermesc 报告的字节码版本号"; }
  ok "hermesc 报告的字节码版本：$v"
  note "接进 RN 工程之前，拿同一个 RN 版本的 sdks/.hermesv1version 对一下 tag。"

  step "3/4  反过来能不能读"
  # 只验「编得出来」不够 —— 得确认那个 .hbc 是结构完整的，不是一堆字节。
  "$OUT" -dump-bytecode "$T/a.js" > "$T/dump.txt" 2>"$T/3.log" \
    || { sed 's/^/      /' "$T/3.log" >&2; die "-dump-bytecode 失败"; }
  grep -q 'Function<add>' "$T/dump.txt" \
    || die "反汇编里找不到 Function<add> —— 编出来的东西不对"
  ok "反汇编里能看到 Function<add>，字节码是完整的"

  step "4/4  跟官方那份逐字节比对"
  # 第五节第 6 条：「和官方行为一致」要变成可检查的。这里能做到最强的那种 ——
  # **同一份 JS，两个编译器出的 .hbc 逐字节比**。
  #
  # 官方只发 x86_64，所以这条要么在 x86 机器上跑，要么这台装了 qemu-user。
  # **跑不了就明说没验，不当过。**
  #
  # npm 包的版本号跟 tag 是对得上的：hermes-v<版本> <-> hermes-compiler@<版本>，
  # 这条是实测出来的（RN 0.87.1 的 sdks/.hermesv1version 是 hermes-v250829098.0.17，
  # 而 npm 上 hermes-compiler 的 latest 就是 250829098.0.17）。
  OFFV="${HERMES_TAG#hermes-v}"
  OFFDIR="$WORK/hermes-official/$OFFV"
  OFF="$OFFDIR/package/hermesc/linux64-bin/hermesc"
  if [ ! -x "$OFF" ]; then
    if command -v curl >/dev/null; then
      note "取官方那份来比对：hermes-compiler@$OFFV"
      mkdir -p "$OFFDIR"
      if curl -fsSL -o "$OFFDIR/hc.tgz" \
           "https://registry.npmjs.org/hermes-compiler/-/hermes-compiler-$OFFV.tgz" 2>/dev/null; then
        tar -C "$OFFDIR" -xzf "$OFFDIR/hc.tgz" 2>/dev/null
      fi
    fi
  fi
  if [ ! -x "$OFF" ]; then
    warn "没有官方那份 hermesc（$OFF），**这一条没验过**。"
    note "手动取：curl -L https://registry.npmjs.org/hermes-compiler/-/hermes-compiler-$OFFV.tgz | tar -xz -C $OFFDIR"
  elif ! "$OFF" -version >/dev/null 2>&1; then
    # 「工具在」不等于「工具能用」—— 官方那份是 x86_64 的。
    warn "官方那份是 x86_64，这台跑不了（要 qemu-user 或一台 x86 机器）。"
    note "**这一条没验过** —— 不是比对失败，是没条件比。"
    note "装：sudo apt install -y qemu-user-static"
  else
    cat > "$T/big.js" <<'JS'
'use strict';
function mk(n) { var a = []; for (var i = 0; i < n; i++) a.push(i * 3 + 1); return a; }
function sum(a) { var t = 0; for (var i = 0; i < a.length; i++) t += a[i]; return t; }
var o = { k: 1, s: 'v', arr: mk(64), nested: { deep: { deeper: [1, 2, 3] } } };
var m = mk(128).map(function (x) { return x * 2; }).filter(function (x) { return x % 3 === 0; });
try { null.x; } catch (e) { o.k += 1; }
print(sum(m), JSON.stringify(o.nested), o.arr.join(','));
JS
    # **两边必须用一模一样的调法。** hermesc 把源文件路径编进 .hbc 里：
    # 同一份 JS，用 `cmp/big.js` 调和用 `/some/longer/path/cmp/big.js` 调，产物差
    # 正好 13 字节 —— 就是那两个路径的长度差（实测）。所以比对时两边传同一个
    # 字符串（这里都是 "$T/big.js"），别一边相对一边绝对。
    # 跟 make_f2fs 那次「黄金值把跑它的那台机器烤进去了」是同一类：
    # **产物里藏着调用环境。**
    nsame=0; ndiff=0
    for opt in "" "-O" "-g"; do
      # shellcheck disable=SC2086
      "$OUT" -emit-binary $opt -out "$T/ours.hbc" "$T/big.js" >/dev/null 2>&1; ro=$?
      # shellcheck disable=SC2086
      "$OFF" -emit-binary $opt -out "$T/off.hbc"  "$T/big.js" >/dev/null 2>&1; rf=$?
      # **两边的结果都要记**：只看我们这边挂没挂，会把「两边都不支持」误报成
      # 「我们编不了」。这个仓库记过这条（反证挂在别处那次）。
      if [ "$ro" != "$rf" ]; then
        die "同一份输入，我们的退出码 $ro、官方 $rf（参数「${opt:-无}」）—— 行为就不一致"
      fi
      [ "$ro" = 0 ] || { note "参数「${opt:-无}」两边都编不了，跳过（一致）"; continue; }
      if cmp -s "$T/ours.hbc" "$T/off.hbc"; then
        nsame=$((nsame+1))
      else
        ndiff=$((ndiff+1))
        warn "参数「${opt:-无}」：$(cmp -l "$T/ours.hbc" "$T/off.hbc" | wc -l) 个字节不同"
      fi
    done
    [ "$ndiff" = 0 ] || die "跟官方那份出的字节码不一致（见上）"
    # 判零和判过要分开说 —— 这个仓库栽过「0 个也印成都对」。
    [ "$nsame" -gt 0 ] || die "一组参数都没比成 —— 这条等于没验"
    ok "$nsame 组参数下，跟官方 hermesc 出的 .hbc **逐字节一致**"
  fi

  step "接进 RN 工程的三条路（都不用打补丁）"
  note "1. 工程的 android/build.gradle 里："
  note "     react { hermesCommand = \"$OUT\" }"
  note "2. 环境变量：REACT_NATIVE_OVERRIDE_HERMES_DIR=<hermes 源码目录>"
  note "   （它会去找 <那个目录>/build/bin/hermesc）"
  note "3. 摆到 node_modules/react-native/sdks/hermes/build/bin/hermesc"
  note "   —— 这是 RN 官方的「从源码编 Hermes」那条路径，插件会自动认。"
  note ""
  note "解析顺序见 @react-native/gradle-plugin 的 utils/PathUtils.kt:50。"
  ok "这份 hermesc 是自己编的，可以用了"
fi
