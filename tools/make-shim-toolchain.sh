#!/usr/bin/env bash
# 在 NDK 里搭一个 linux-aarch64 的「薄壳」host 工具链。
#
# 它不编译任何东西。做的是：
#   bin/clang, bin/clang++     包装脚本 -> 系统 clang，补上 NDK 的默认值
#   bin/<triple><api>-clang    照抄 x86_64 那份的清单，加 --target 后转发
#   bin/llvm-*, ld.lld         软链到系统 LLVM 的同名工具
#   sysroot/                   软链到 linux-x86_64 那份（跟 host 无关，已验证）
#   lib/clang/<ver>/           同上（compiler-rt + 内建头文件，也跟 host 无关）
#   python3/bin/python3        软链到系统 python3（补 init.mk 那个兜底坑）
#
# 为什么可行：系统 clang 和 NDK clang 的差别，在「编 Android 目标」这条路径上
# 是编译时默认值，不是 LLVM 的私有补丁。默认值能用命令行补。详见 README 第四节。
#
# 局限（别当成最终形态）：
#   - 依赖发行版的 clang，版本必须和 NDK 的 resource dir 对得上
#   - 达不到 README 第四节「和官方 x86_64 版行为一致」那条标准
#   - 只是让 tests/hello-native 能早点跑起来
#
# 用法：  tools/make-shim-toolchain.sh [--remove] [ndk 路径]

set -euo pipefail

MODE=make
if [ "${1:-}" = "--remove" ]; then MODE=remove; shift; fi

# ---- 找 NDK ----
NDK="${1:-}"
if [ -z "$NDK" ]; then
  for c in "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK:-}" \
           "${ANDROID_HOME:-}"/ndk/* "${ANDROID_SDK_ROOT:-}"/ndk/*; do
    if [ -n "$c" ] && [ -d "$c/toolchains/llvm/prebuilt" ]; then NDK="$c"; break; fi
  done
fi
[ -n "$NDK" ] && [ -d "$NDK/toolchains/llvm/prebuilt" ] || {
  echo "没找到 NDK。传路径：tools/make-shim-toolchain.sh /path/to/ndk"; exit 1; }
NDK=$(cd "$NDK" && pwd)

SRC="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
DST="$NDK/toolchains/llvm/prebuilt/linux-aarch64"

if [ "$MODE" = remove ]; then
  [ -e "$DST" ] || [ -e "$NDK/prebuilt/linux-aarch64" ] || { echo "本来就没有"; exit 0; }
  rm -rf "$DST" "$NDK/prebuilt/linux-aarch64"
  echo "已删除 $DST"
  echo "已删除 $NDK/prebuilt/linux-aarch64"
  exit 0
fi

[ -d "$SRC" ] || { echo "找不到 $SRC —— 这个薄壳要从 x86_64 那份借 sysroot"; exit 1; }

case "$(uname -m)" in
  aarch64|arm64) ;;
  *) echo "警告：这台不是 aarch64。搭出来的东西只能在 aarch64 上用。" >&2 ;;
esac

# ---- 找系统 clang，核对版本 ----
SYSCLANG=$(command -v clang || true)
[ -n "$SYSCLANG" ] || { echo "没有系统 clang：sudo apt install -y clang lld"; exit 1; }
SYSCLANG=$(readlink -f "$SYSCLANG")
SYSVER=$(clang -dumpversion | cut -d. -f1)

RESVER=""
for d in "$SRC"/lib/clang/*/; do RESVER=$(basename "$d"); done
[ -n "$RESVER" ] || { echo "$SRC/lib/clang 底下什么都没有"; exit 1; }

echo "NDK          $NDK"
echo "系统 clang   $SYSCLANG (版本 $SYSVER)"
echo "NDK resource dir  lib/clang/$RESVER"
if [ "$SYSVER" != "$RESVER" ]; then
  echo
  echo "  ✗ 版本对不上：系统 clang 是 $SYSVER，NDK 的 resource dir 是 $RESVER。"
  echo "    resource dir 里的 compiler-rt 是按 $RESVER 的 ABI 编的，混用不安全。"
  echo "    装一个匹配的：sudo apt install -y clang-$RESVER lld-$RESVER"
  exit 1
fi
echo

# ---- 开建 ----
rm -rf "$DST"
mkdir -p "$DST/bin" "$DST/python3/bin"

# 留个标记：verify-claims 靠它把薄壳和「真的要重编的 host 目录」区分开，
# 也免得它拿这份（sysroot 和 lib/clang 都是软链）去量体积算出负数。
cat > "$DST/.shim-generated" <<MARK
由 tools/make-shim-toolchain.sh 生成，不是编出来的工具链。
clang / clang++ 是转发到系统 clang 的包装脚本；
sysroot 和 lib/clang 是软链到 linux-x86_64 那份。
删除：tools/make-shim-toolchain.sh --remove
MARK

# 跟 host 无关的两块，直接软链（省 750 MB，要做分发包时改成 cp -a）
ln -s "../linux-x86_64/sysroot" "$DST/sysroot"
mkdir -p "$DST/lib"
ln -s "../../linux-x86_64/lib/clang" "$DST/lib/clang"

# ---- bin/clang 和 bin/clang++ ----
mkwrapper() {  # $1=名字  $2=真实命令  $3=要不要加 -stdlib=libc++
  cat > "$DST/bin/$1" <<'WRAP'
#!/bin/sh
# 由 tools/make-shim-toolchain.sh 生成，别手改。
# 把 NDK clang 的编译时默认值用命令行补给系统 clang。
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")

# 只编译不链接的话，链接相关的 flag 一个都别传 —— 否则每个 .o 都会带出一串
# "argument unused during compilation" 警告，几百行下来会把真正的警告淹掉。
linking=1
arch=
prev=
for a in "$@"; do
  case "$a" in
    -c|-S|-E|-fsyntax-only|-M|-MM) linking=0 ;;
  esac
  t=
  case "$a" in --target=*) t=${a#--target=} ;; esac
  case "$prev" in -target) t=$a ;; esac
  prev=$a
  [ -n "$t" ] || continue
  case "$t" in
    aarch64-*)        arch=aarch64 ;;
    armv7a-*|arm-*)   arch=arm ;;
    i686-*)           arch=i386 ;;
    x86_64-*)         arch=x86_64 ;;
    riscv64-*)        arch=riscv64 ;;
  esac
done

# 编译和链接都要的
set -- --sysroot="$ROOT/sysroot"        -resource-dir="$ROOT/lib/clang/@RESVER@"        @STDLIB@ "$@"

# 只有链接才要的
if [ "$linking" = 1 ]; then
  set -- -rtlib=compiler-rt -unwindlib=libunwind -fuse-ld=lld "$@"
  [ -n "$arch" ] && set -- -L"$ROOT/lib/clang/@RESVER@/lib/linux/$arch" "$@"
fi

# 注意：故意不传 -femulated-tls。NDK 在 API<29 用模拟 TLS、>=29 用原生，
# 这个判断在上游 driver 里，系统 clang 自己会做。写死会在 API>=29 上出错。
exec @REAL@ "$@"
WRAP
  sed -i "s|@RESVER@|$RESVER|g; s|@REAL@|$2|g; s|@STDLIB@|$3|g" "$DST/bin/$1"
  chmod +x "$DST/bin/$1"
}
SYSCLANGXX=$(command -v clang++ || echo "$SYSCLANG")
# -stdlib 只给 clang++：sysroot 里的 libstdc++.a 是个只有四个符号的桩
# （__cxa_guard_* 和 __cxa_pure_virtual），而 libc++.a 是链接脚本
# INPUT(-lc++_static -lc++abi)。系统 clang 默认 -stdlib=libstdc++ 会去链那个桩，
# 结果 libc++abi 进不来，链接期报一堆 std::exception / vtable 未定义。
# 给 clang（C 驱动）加 -stdlib 只会换来 unused 警告，所以只给 clang++。
mkwrapper clang   "$SYSCLANG"                      ""
mkwrapper clang++ "$(readlink -f "$SYSCLANGXX")"   "-stdlib=libc++"

# ---- 三元组前缀的包装：照抄 x86_64 那份有哪些就做哪些 ----
n_triple=0
for f in "$SRC"/bin/*-linux-android*-clang "$SRC"/bin/*-linux-android*-clang++; do
  [ -f "$f" ] || continue
  base=$(basename "$f")
  case "$base" in *.cmd) continue ;; esac
  triple=${base%-clang}; triple=${triple%-clang++}
  drv=clang; case "$base" in *-clang++) drv=clang++ ;; esac
  cat > "$DST/bin/$base" <<WRAPT
#!/bin/sh
# 由 tools/make-shim-toolchain.sh 生成。跟 NDK 原版同样的形状：加 --target 后转发。
bin_dir=\$(dirname "\$0")
if [ "\$1" != "-cc1" ]; then
    "\$bin_dir/$drv" --target=$triple "\$@"
else
    "\$bin_dir/$drv" "\$@"
fi
WRAPT
  chmod +x "$DST/bin/$base"
  n_triple=$((n_triple + 1))
done

# ---- llvm-* / ld.lld 等：软链到系统同名工具，缺的记下来 ----
SYSBIN=$(dirname "$SYSCLANG")
n_link=0; missing=""
for f in "$SRC"/bin/*; do
  base=$(basename "$f")
  case "$base" in
    *.cmd|*.exe|*.dll|clang|clang++|*-linux-android*) continue ;;
  esac
  [ -e "$DST/bin/$base" ] && continue
  if [ -x "$SYSBIN/$base" ]; then
    ln -s "$SYSBIN/$base" "$DST/bin/$base"; n_link=$((n_link + 1))
  elif t=$(command -v "$base" 2>/dev/null); then
    ln -s "$t" "$DST/bin/$base"; n_link=$((n_link + 1))
  else
    missing="$missing $base"
  fi
done

# ---- python3：补 init.mk 的兜底坑（它找不到就退回裸 python）----
if p=$(command -v python3); then ln -s "$p" "$DST/python3/bin/python3"; fi

# ---- 顶层 prebuilt/<tag>/bin：ndk-build 找 make 的地方 ----
# 找不到会退回系统 make（实测能用），软链过去只是让这个 host tag 完整。
PRE="$NDK/prebuilt/linux-aarch64/bin"
rm -rf "$NDK/prebuilt/linux-aarch64"
mkdir -p "$PRE"
cp "$DST/.shim-generated" "$NDK/prebuilt/linux-aarch64/.shim-generated"
n_pre=0
for t in make yasm ndk-which; do
  if x=$(command -v "$t" 2>/dev/null); then ln -s "$x" "$PRE/$t"; n_pre=$((n_pre + 1)); fi
done

echo "搭好了：$DST"
echo "  clang / clang++ 包装      2"
echo "  三元组前缀包装            $n_triple"
echo "  软链到系统的工具          $n_link"
echo "  sysroot, lib/clang/$RESVER  软链自 linux-x86_64"
echo "  prebuilt/linux-aarch64/bin  $n_pre 个（make 等）"
if [ -n "$missing" ]; then
  echo
  echo "系统 LLVM 里没有、因此缺的（用到才会出问题）："
  for m in $missing; do echo "    $m"; done
fi
# **薄壳单独存在是没用的。** 它只是把工具链摆到 prebuilt/linux-aarch64，
# 而「去那儿找」是 patches/ndk/ 那几个补丁的事。少了补丁，NDK 的 cmake 仍然选
# linux-x86_64，于是在 ARM64 上编东西会得到一句 `Exec format error` ——
# 报错在两分钟之后的 cmake 里，跟真因隔着十万八千里。
# smoke-build 真栽过：它只跑了这个脚本，没跑 patch-ndk.sh。
tc_cmake="$NDK/build/cmake/android.toolchain.cmake"
if [ -f "$tc_cmake" ] && ! grep -q 'CMAKE_HOST_SYSTEM_PROCESSOR' "$tc_cmake"; then
  echo
  echo "  ⚠ 这份 NDK **还没打过 host tag 的补丁**。"
  echo "    薄壳摆好了，但 NDK 的 cmake 仍然只认 linux-x86_64 —— 现在去编东西"
  echo "    会在 cmake 里报 'Exec format error'（它去跑了 x86_64 的 clang）。"
  echo "    先跑：tools/patch-ndk.sh \"$NDK\""
  exit 1
fi

echo
echo "验一下："
echo "  tools/verify-claims.sh              # 第 3 节应该报 clang 已就位"
echo "  cd /tmp/ndktest && \$ANDROID_NDK_HOME/ndk-build APP_ABI=arm64-v8a NDK_APPLICATION_MK=/dev/null"
