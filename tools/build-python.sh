#!/usr/bin/env bash
# 编 NDK 工具链里那份 python3。
#
# **它是 host 工具链最后一处不自足的地方。** tools/build-llvm.sh 编出来的
# prebuilt/<tag>/ 里，python3/ 一直是软链到系统的 python3 —— 够用，但那份
# prebuilt 就没法单独打包分发（M4 要用）。
#
# ---------------------------------------------------------------------------
# 源码取哪份，版本对不对得上
#
# Google 自己**不编** CPython：llvm_android 里只有 paths.get_python_lib() 之类，
# 用的是 AOSP 的 prebuilts/python。所以这里没有「照抄 build.py」这条路，
# 权威只能是两样：
#
#   1. **NDK 实际发的那份长什么样** —— 3.11.4，RPATH=$ORIGIN/../lib，
#      lib-dynload 里 69 个扩展模块，lib/python3.11 里没有 test/ idlelib
#      tkinter config-*（Google 裁过）。
#   2. **源码从跟别的工具同一个 AOSP tag 取** —— external/python/cpython3
#      在 platform-tools-35.0.2 上正好就是 **3.11.4**，跟 NDK 发的那份同版本。
#      这不是巧合也不是凑的，是查出来的：
#          Include/patchlevel.h -> PY_VERSION "3.11.4"
#
# ---------------------------------------------------------------------------
# 有意跟 NDK 那份不一样的地方
#
#   1. **不做 PGO/LTO**（不加 --enable-optimizations）。跟 LLVM 那边同一个理由：
#      成倍的机时，而且只影响 python 自己跑多快。**这次没有黄金值能验它** ——
#      python 不像编译器有确定输出，所以这条只是「有理由的省」，不是「验过的省」。
#      写清楚，别混为一谈。
#   2. 模块集合**按系统上有什么库来**。NDK 那份没有 _ssl / _hashlib /
#      _sqlite3 / _lzma / readline —— 我们也不特意去补。--verify 会逐个对
#      NDK 那份的模块名单，**少了算错，多了只提示**。
#
# 用法：tools/build-python.sh [--fetch|--build|--verify]

set -uo pipefail

die()  { printf '\n  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1" >&2; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$REPO/work}"
SRC="$WORK/python/cpython3"
BUILD="$WORK/python/build"
AOSP_TAG=platform-tools-35.0.2          # 跟 tools/build-common.sh 一致
PY_VERSION=3.11.4
PY_XY=3.11

case "$(uname -m)" in
  x86_64)        HOST_TAG=linux-x86_64 ;;
  aarch64|arm64) HOST_TAG=linux-aarch64 ;;
  *) die "没见过的架构 $(uname -m)" ;;
esac
OUT="${PYTHON_OUT:-$WORK/out/python3/$HOST_TAG}"

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

find_ndk_python() {   # 参照物：NDK 自带那份（跟 host 架构无关的部分才拿来比）
  NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK:-}}"
  if [ -z "$NDK" ]; then
    for c in "$WORK"/android-ndk-* "${ANDROID_HOME:-}"/ndk/* "${ANDROID_SDK_ROOT:-}"/ndk/*; do
      [ -d "$c/toolchains/llvm/prebuilt" ] && { NDK="$c"; break; }
    done
  fi
  [ -n "$NDK" ] && [ -d "$NDK/toolchains/llvm/prebuilt" ] || die "找不到 NDK"
  NDK=$(cd "$NDK" && pwd)
  REF="$NDK/toolchains/llvm/prebuilt/linux-x86_64/python3"
  [ -d "$REF" ] || die "$REF 不在 —— 要拿它的模块名单当参照"
}

# ---------------------------------------------------------------------- fetch
if [ "$DO_FETCH" = 1 ]; then
  step "查家伙什"
  for t in git make gcc; do
    command -v "$t" >/dev/null || die "没有 $t：sudo apt install -y git build-essential"
  done
  # 这几个头文件决定编出哪些扩展模块。缺了不会报错，**只会静默少几个模块** ——
  # 所以在这儿拦，别等到 --verify 才发现名单对不上。
  miss=""
  [ -f /usr/include/zlib.h ]        || miss="$miss zlib1g-dev(zlib)"
  [ -f /usr/include/bzlib.h ]       || miss="$miss libbz2-dev(_bz2)"
  # **一个头文件可能在好几个位置**（多架构目录 /usr/include/<triple>/）。
  # 别写成 `ls a b` —— 只要有一个不存在 ls 就返回非零，哪怕另一个在。
  # 第一版就是那么写的，明明装了 libffi-dev 还报缺。写个函数逐个试。
  have_hdr() { for h in "$@"; do [ -f "$h" ] && return 0; done; return 1; }
  have_hdr /usr/include/ffi.h /usr/include/*/ffi.h \
      || miss="$miss libffi-dev(_ctypes)"
  have_hdr /usr/include/ncursesw/curses.h /usr/include/curses.h /usr/include/*/curses.h \
      || miss="$miss libncurses-dev(_curses)"
  # nis 是个已经废弃的模块（3.13 里删掉了），但 **NDK 那份带着它**，
  # 第 3 步是「少了算错」，所以这里也得有。一个 apt 包的事。
  have_hdr /usr/include/rpcsvc/ypclnt.h /usr/include/*/rpcsvc/ypclnt.h \
      || miss="$miss libnsl-dev(nis)"
  [ -z "$miss" ] || die "缺开发头文件，编出来会**静默少几个模块**：$miss
    sudo apt install -y zlib1g-dev libbz2-dev libffi-dev libncurses-dev libnsl-dev"
  ok "编译器和四组头文件都在"

  step "取源码"
  if [ -d "$SRC/.git" ]; then
    note "$SRC 已经在了"
  else
    mkdir -p "$(dirname "$SRC")"
    git clone --depth 1 --branch "$AOSP_TAG" -c advice.detachedHead=false \
        https://android.googlesource.com/platform/external/python/cpython3 "$SRC" \
      || die "clone 失败"
  fi
  v=$(sed -n 's/^#define PY_VERSION *"\(.*\)"$/\1/p' "$SRC/Include/patchlevel.h")
  [ "$v" = "$PY_VERSION" ] || die "源码是 $v，NDK 发的是 $PY_VERSION。
    **别将就编** —— 换个版本编出来的 python3 跟 NDK 那份不是一回事。
    先确认 AOSP tag $AOSP_TAG 上的 cpython3 现在是哪版。"
  ok "cpython3 $v（AOSP $AOSP_TAG），跟 NDK 发的那份同版本"
fi

# ---------------------------------------------------------------------- build
if [ "$DO_BUILD" = 1 ]; then
  [ -f "$SRC/configure" ] || die "源码不在，先跑 tools/build-python.sh --fetch"
  find_ndk_python
  rm -rf "$BUILD" "$OUT"; mkdir -p "$BUILD"

  step "configure"
  # --enable-shared + RPATH=$ORIGIN/../lib：照 NDK 那份的形状。
  #   readelf -d <ndk>/python3/bin/python3 -> RPATH [$ORIGIN/../lib]
  #
  # **那个 $ 要写成 \$$**。它要穿过三层：bash 的单引号（原样）、configure 存进
  # Makefile、make 展开（$$ -> $）、最后是 make 调起来的 sh（\$ -> $）。
  # 第一版写成 '$ORIGIN'，make 把 $O 当成自己的变量吃掉了，产物里的 RUNPATH
  # 变成 "RIGIN/../lib" —— 于是 bin/python3 加载的是**系统那份**
  # libpython3.11.so.1.0，报的版本是系统的 3.11.15 而不是 3.11.4。
  #
  # **「自足」这件事必须被测，不能被声明。** 第 2 步的版本检查和 rpath 检查
  # 各自都能抓到这一条（实际是版本那条先红的）。
  # --with-ensurepip=no：NDK 那份也没带 pip（lib/python3.11 里没有 ensurepip）。
  ( cd "$BUILD" && "$SRC/configure" \
      --prefix="$OUT" \
      --enable-shared \
      --with-ensurepip=no \
      LDFLAGS='-Wl,-rpath,\$$ORIGIN/../lib' \
      >"$BUILD/configure.log" 2>&1 ) \
    || { tail -30 "$BUILD/configure.log" >&2; die "configure 失败"; }
  ok "配置完成"

  step "make（$(nproc) 核）"
  t0=$(date +%s)
  ( cd "$BUILD" && make -j"$(nproc)" >"$BUILD/make.log" 2>&1 ) \
    || { tail -30 "$BUILD/make.log" >&2; die "make 失败"; }
  # CPython 的 make 对缺库是**只警告不报错**的，所以这里主动看一眼。
  if grep -q "Could not build the ssl module\|necessary bits to build these" "$BUILD/make.log"; then
    note "有模块没编出来（这是 CPython 的常态，NDK 那份也缺几个）："
    sed -n '/necessary bits to build these/,+3p' "$BUILD/make.log" | sed 's/^/      /'
    note "第 3 步会逐个对 NDK 的名单，真缺了会红。"
  fi
  ok "编完，用了 $(( ($(date +%s)-t0)/60 )) 分钟"

  step "make install"
  ( cd "$BUILD" && make install >"$BUILD/install.log" 2>&1 ) \
    || { tail -20 "$BUILD/install.log" >&2; die "make install 失败"; }

  step "裁到 NDK 那份的形状"
  # NDK 那份 lib/python3.11 里没有这几样，数过。裁掉省一半体积。
  n0=$(du -sm "$OUT" | cut -f1)
  rm -rf "$OUT/lib/python$PY_XY/test" "$OUT/lib/python$PY_XY/idlelib" \
         "$OUT/lib/python$PY_XY/tkinter" "$OUT/lib/python$PY_XY/config-$PY_XY"*
  find "$OUT" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null
  ok "$n0 MB -> $(du -sm "$OUT" | cut -f1) MB（NDK 那份是 $(du -sm "$REF" | cut -f1) MB）"

  step "编好了"
  note "$OUT"
  note ""
  note "验它：tools/build-python.sh --verify"
  note "装进工具链：tools/build-llvm.sh --build 会自动用它（它在就拷，不在就软链系统的）"
fi

# --------------------------------------------------------------------- verify
if [ "$DO_VERIFY" = 1 ]; then
  PY="$OUT/bin/python3"
  [ -x "$PY" ] || die "$PY 不在，先跑 tools/build-python.sh --build"
  find_ndk_python
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

  step "验自己编的这份 python3"

  step "1/4  先让它红一次：跑一段必然抛异常的代码"
  if "$PY" -c 'import sys; sys.exit(0 if 1/0 else 1)' >/dev/null 2>&1; then
    die "1/0 居然没炸 —— 那后面几步测的根本不是「跑 python」这件事"
  fi
  ok "红了"

  step "2/4  版本和自足性"
  v=$("$PY" -c 'import sys;print(sys.version.split()[0])' 2>&1) || die "跑不起来：$v"
  [ "$v" = "$PY_VERSION" ] || die "版本是 $v，应该 $PY_VERSION"
  ok "$v"
  # **这一条才是这个工具存在的理由**：它不能再依赖系统的 python。
  # 判据是 sys.prefix 指向我们这份，而且 libpython 是从自己的 lib/ 找到的。
  p=$("$PY" -c 'import sys;print(sys.prefix)')
  [ "$p" = "$OUT" ] || die "sys.prefix 是 $p，应该 $OUT —— 它在用别人的 stdlib"
  ok "sys.prefix = $OUT（自带 stdlib，不是借系统的）"
  _rp=$(readelf -d "$PY" 2>/dev/null)   # 不走管道
  grep -q 'RPATH.*ORIGIN/../lib\|RUNPATH.*ORIGIN/../lib' <<<"$_rp" \
    || die "bin/python3 没有 \$ORIGIN/../lib 的 rpath —— 换个目录/换台机器就找不到 libpython"
  ok "rpath = \$ORIGIN/../lib（跟 NDK 那份一样）"

  step "3/4  扩展模块名单跟 NDK 那份逐个对"
  # **少了算错，多了只提示。** 名单是从 NDK 自带那份数出来的，去掉架构后缀。
  ls "$REF/lib/python$PY_XY/lib-dynload/" | sed 's/\.cpython-.*//' | sort -u > "$T/ref.txt"
  ls "$OUT/lib/python$PY_XY/lib-dynload/" | sed 's/\.cpython-.*//' | sort -u > "$T/ours.txt"
  missing=$(comm -23 "$T/ref.txt" "$T/ours.txt" | tr '\n' ' ')
  extra=$(comm -13 "$T/ref.txt" "$T/ours.txt" | tr '\n' ' ')
  [ -z "$(echo "$missing" | tr -d ' ')" ] || die "NDK 那份有、我们没有的模块：
      $missing
    多半是 --fetch 时那几个开发头文件没装全，CPython 的 make 对这个**只警告不报错**。
    装上重编：sudo apt install -y zlib1g-dev libbz2-dev libffi-dev libncurses-dev libnsl-dev"
  ok "NDK 的 $(wc -l < "$T/ref.txt") 个模块一个不少"
  [ -z "$(echo "$extra" | tr -d ' ')" ] || note "另外多出 $(echo "$extra" | wc -w) 个（不算错）：$extra"

  step "4/4  真拿它跑 ndk-build 用到的那几个脚本"
  # 这才是它要干的活。ndk-build 只用 HOST_PYTHON 跑五个脚本，全是标准库。
  # 见 patches/ndk/README.md 里 0005 那段。
  B="$NDK/build"
  n=0
  for s in ldflags_to_sanitizers.py extract_platform.py extract_manifest.py \
           gen_compile_db.py dump_compile_commands.py; do
    f=$(find "$B" -name "$s" | head -1)
    [ -n "$f" ] || { note "$s 不在这个 NDK 里，跳过"; continue; }
    # 都能用 --help 或者不给参数走到参数解析，不碰真文件
    "$PY" "$f" --help >/dev/null 2>&1 || "$PY" "$f" >/dev/null 2>&1
    rc=$?
    [ "$rc" -lt 2 ] || { "$PY" "$f" --help 2>&1 | head -5 | sed 's/^/      /' >&2
                         die "$s 跑不了（退出码 $rc）—— 缺模块？"; }
    n=$((n+1))
  done
  [ "$n" -ge 4 ] || die "只跑了 $n 个脚本，太少 —— NDK 的目录结构变了？"
  ok "$n 个脚本都跑得起来"

  step "这份 python3 是自己编的，可以用了"
  note "$OUT（$(du -sm "$OUT" | cut -f1) MB）"
  note ""
  note "**没做的**：PGO/LTO（不加 --enable-optimizations）。只影响它自己跑多快，"
  note "但跟 LLVM 那边不同，**这次没有黄金值能验这句话** —— python 没有确定输出。"
  note "算「有理由的省」，不算「验过的省」。"
fi
