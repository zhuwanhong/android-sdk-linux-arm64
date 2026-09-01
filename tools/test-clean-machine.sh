#!/usr/bin/env bash
# 干净机器验收 —— 这个项目最后一道没做的检查。
#
# 为什么要它：到目前为止**所有**验证都在打包那台机器上做的，而那台为了编
# LLVM 和 CPython 装了一堆东西 —— zlib1g-dev、libffi-dev、libncurses-dev、
# libbz2-dev、系统 clang、cmake、ninja……包在那台上跑得通，说明不了它在别人
# 机器上跑得通。这是第五节第 1 条的同一个道理，只是换了个轴：
# 那条说的是「x86 上编过了不算数」，这条说的是「**编包那台上能用不算数**」。
#
# 两个阶段，各回答一个问题：
#
#   一、量依赖（不用 docker，x86_64 上也能跑）
#       包里的 host 二进制到底连了哪些系统库？要求多高的 glibc？
#       —— glibc 那条尤其要紧：在 Ubuntu 24.04 上编的二进制，
#          在 22.04 上是**开都开不起来**，报 GLIBC_2.38 not found。
#
#   二、裸容器实测（要 docker）
#       从一个什么都没装的镜像开始，逐层加依赖，看每层能走到哪一步。
#       结论不是「能用/不能用」，是**「到底还得装什么」** —— 那句话要写进
#       README 给用户看，所以必须是量出来的，不能是猜的。
#
# 用法：
#   tools/test-clean-machine.sh              两个阶段都跑
#   tools/test-clean-machine.sh --deps       只量依赖（不用 docker）
#   tools/test-clean-machine.sh --docker     只跑容器实测
#
# 包从哪来：默认找 $WORK 底下 make-dist.sh / make-ndk-dist.sh 出的 tar.gz。

set -uo pipefail

die()  { printf '\n  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1" >&2; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$REPO/work}"

_rev=$(git -C "$REPO" log -1 --format='%h %ad' --date=short -- "${BASH_SOURCE[0]}" 2>/dev/null)
printf '  \033[2m%s @ %s\033[0m\n' "$(basename "${BASH_SOURCE[0]}")" "${_rev:-（不在 git 里）}"

DO_DEPS=1; DO_DOCKER=1
case "${1:-}" in
  --deps)   DO_DOCKER=0; shift ;;
  --docker) DO_DEPS=0;   shift ;;
  "") ;;
  *) die "不认识的参数：$1" ;;
esac

SDK_TAR="${SDK_TAR:-}"; NDK_TAR="${NDK_TAR:-}"
[ -n "$SDK_TAR" ] || for f in "$WORK"/android-sdk-linux-arm64-*.tar.gz; do [ -f "$f" ] && SDK_TAR=$f; done
[ -n "$NDK_TAR" ] || for f in "$WORK"/android-ndk-*-linux-aarch64.tar.gz; do [ -f "$f" ] && NDK_TAR=$f; done
[ -f "${SDK_TAR:-/nonexistent}" ] || die "找不到 SDK 包。先跑 tools/make-dist.sh，或者 SDK_TAR=... 指过来"
[ -f "${NDK_TAR:-/nonexistent}" ] || die "找不到 NDK 包。先跑 tools/make-ndk-dist.sh，或者 NDK_TAR=... 指过来"

step "拿这两个包测"
note "SDK  $SDK_TAR（$(du -h "$SDK_TAR" | cut -f1)）"
note "NDK  $NDK_TAR（$(du -h "$NDK_TAR" | cut -f1)）"

# ===========================================================================
if [ "$DO_DEPS" = 1 ]; then

step "这台（打包机）是什么"
. /etc/os-release 2>/dev/null
note "发行版  ${PRETTY_NAME:-不知道}"
note "glibc   $(ldd --version 2>/dev/null | head -1 | grep -o '[0-9]\+\.[0-9]\+$' || echo '读不出来')"
note "架构    $(uname -m)"

command -v readelf >/dev/null || die "没有 readelf(1)，量不了依赖。装 binutils。
    「测不了」和「测过了」不是一回事 —— 这一步不能跳。"

T=$(mktemp -d) || die "mktemp 失败"
trap 'rm -rf "$T"' EXIT
step "解开来看（临时目录，看完就删）"
mkdir -p "$T/x"
tar -C "$T/x" -xzf "$SDK_TAR" || die "SDK 包解不开"
tar -C "$T/x" -xzf "$NDK_TAR" || die "NDK 包解不开"
ok "解开了 $(du -sh "$T/x" | cut -f1)"

# 判据：DT_NEEDED 里有 libc.so.6 的就是 Linux host 二进制。
# Android 目标产物连的是 libc.so（不带 .6）、liblog.so 那一套，天然分得开 ——
# 不用再去猜位置，比 make-ndk-dist.sh 里那份位置名单更省事，也更准。
step "一、这些 host 二进制连了什么"
needed_all=""; n_bin=0
maxv=""; maxf=""
declare -A LIBOF 2>/dev/null || true
while IFS= read -r f; do
  d=$(readelf -d "$f" 2>/dev/null) || continue
  case "$d" in *libc.so.6*) ;; *) continue ;; esac
  n_bin=$((n_bin+1))
  libs=$(printf '%s' "$d" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p')
  needed_all="$needed_all $libs"
  v=$(readelf -W --dyn-syms "$f" 2>/dev/null | grep -o 'GLIBC_[0-9]\+\.[0-9]\+' | sed 's/GLIBC_//' | sort -V | tail -1)
  if [ -n "$v" ]; then
    if [ -z "$maxv" ] || [ "$(printf '%s\n%s\n' "$maxv" "$v" | sort -V | tail -1)" = "$v" ]; then
      if [ "$v" != "$maxv" ]; then maxv=$v; maxf=${f#"$T/x"/}; fi
    fi
  fi
done < <(find "$T/x" -type f)
[ "$n_bin" -ge 20 ] || die "只找到 $n_bin 个 Linux host 二进制，太少了 —— 包不对，或者判据写错了。"

# 这几个不算「额外依赖」：任何跑得起 glibc 程序的机器上都有。
# libgcc_s.so.1 严格说不是 glibc 的（是 GCC 的运行时），但 glibc 自己就依赖它，
# 没有它系统根本起不来 —— 归到这一组是对的。
GLIBC_OWN=" libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 libresolv.so.2 libutil.so.1 libnsl.so.1 libgcc_s.so.1 ld-linux-aarch64.so.1 ld-linux-x86-64.so.2 "
extra=$(printf '%s' "$needed_all" | tr ' ' '\n' | grep -v '^$' | sort -u | while read -r l; do
  case "$GLIBC_OWN" in *" $l "*) continue ;; esac
  # 包自带的（我们自己编的 libc++ 之类）也不算 —— 它们就在包里
  _hit=$(find "$T/x" -name "$l" -print -quit); [ -n "$_hit" ] && continue
  echo "$l"
done)
ok "$n_bin 个 Linux host 二进制"
if [ -z "$extra" ]; then
  ok "除了 glibc 那套和包自带的，不连任何别的系统库"
else
  warn "还连着这些库，得由机器提供："
  for l in $extra; do
    who=$(while IFS= read -r f; do
            grep -q "\[$l\]" <<<"$(readelf -d "$f" 2>/dev/null)" && { echo "${f#"$T/x"/}"; break; }
          done < <(find "$T/x" -type f))
    note "  $l        （比如 $who 要它）"
  done
  note ""
  note "**别在这里下结论说「这些都是基础包，肯定有」。** 有没有是第三节的裸容器"
  note "实测回答的 —— 那才是这个脚本存在的意义。"
fi

step "二、要求多高的 glibc"
# 这条决定了包能装在哪些发行版上。二进制里引用的 GLIBC_x.y 符号版本，
# 最高的那个就是门槛 —— 低于它的系统上**开都开不起来**，
# 报 `version GLIBC_x.y not found`，跟「缺个库」不是一回事。
[ -n "$maxv" ] || die "一个 GLIBC_ 符号版本都没读出来 —— 这条没量到，别当它过了。"
note "最高要 GLIBC_$maxv"
note "顶上去的是 $maxf"
note ""
note "参考对照（以实测为准）："
note "  2.31 = Ubuntu 20.04 / Debian 11      2.35 = Ubuntu 22.04"
note "  2.36 = Debian 12                     2.39 = Ubuntu 24.04"
note ""
note "作个参照：官方 x86_64 NDK 的 clang 只要 GLIBC_2.16 —— Google 是拿老"
note "sysroot 编的。我们直接在打包机上编，门槛就是打包机的 glibc。"
note "**这不是 bug，是取舍**：换来的是不用维护一套 sysroot。但它决定了"
note "这个包发给谁能用，所以必须量出来写在明处。"

fi

# ===========================================================================
if [ "$DO_DOCKER" = 1 ]; then

step "三、裸容器实测"
# 光看 `command -v docker` 不够 —— 客户端装着、守护进程没跑，是最常见的情况，
# 而那时候每个镜像都会安静地印一片「（没走到）」，看着像跑过了。
# 这条自己就踩过一次。
docker_ok=0
command -v docker >/dev/null && docker info >/dev/null 2>&1 && docker_ok=1
[ "$docker_ok" = 1 ] || {
  if command -v docker >/dev/null; then
    warn "docker 客户端在，但守护进程连不上，**这一段没测**。"
  else
    warn "没有 docker，**这一段没测**。"
  fi
  note "手工做法：开一台全新的 ARM64 机器（或 podman/lxc 起个干净容器），"
  note "把两个 tar.gz 拷过去，照下面这张表一层层试。"
  note "别在打包这台上试 —— 那台什么都装过了，测不出东西来。"
  exit 0
}

PKGDIR=$(mktemp -d) || die "mktemp 失败"
cp "$SDK_TAR" "$PKGDIR/sdk.tar.gz" && cp "$NDK_TAR" "$PKGDIR/ndk.tar.gz" || die "拷包失败"
mkdir -p "$PKGDIR/tests" && cp -a "$REPO/tests/." "$PKGDIR/tests/" || die "拷 tests 失败"
rm -rf "$PKGDIR"/tests/*/build "$PKGDIR"/tests/*/libs "$PKGDIR"/tests/*/obj
trap 'rm -rf "$PKGDIR" "${T:-}"' EXIT

IMAGES="${IMAGES:-ubuntu:24.04 ubuntu:22.04 debian:12}"
note "镜像：$IMAGES"
note "每个镜像从**什么都不装**开始，逐层加，看能走到哪一步："
note "  L0 裸镜像            -> 目标 T1：clang --version 能起来"
note "  L1 + make            -> 目标 T2：ndk-build 编出一个 .so"
note "  L2 + JDK + zip       （还编不了 APK，缺 android.jar）"
  note "  L3 + platforms/android-XX -> 目标 T3：hello-native 出 APK"
  note "     （SDK 包有意不含 platforms/，干净机器上得自己下 65 MB）"
note ""

# 容器里要跑的那段单独落成文件 —— 嵌到 $( ) 里的 heredoc 解析起来太脆，
# bash 得先在里面找配对的括号，Android.mk 里那些 $(CLEAR_VARS) 正好把它带沟里。
cat > "$PKGDIR/inner.sh" <<'INNER'
set -u
mark() { echo "@@MARK $*"; }
export DEBIAN_FRONTEND=noninteractive
mkdir -p /sdk && tar -C /sdk -xzf /pkg/sdk.tar.gz && tar -C /sdk -xzf /pkg/ndk.tar.gz \
  || { mark UNPACK fail; exit 0; }
mark UNPACK ok
export ANDROID_HOME=/sdk
NDK=$(ls -d /sdk/ndk/*/ 2>/dev/null | head -1); NDK=${NDK%/}
CLANG=$NDK/toolchains/llvm/prebuilt/linux-aarch64/bin/clang
[ -x "$CLANG" ] || { mark T1 "fail 找不到 $CLANG"; exit 0; }

# ---- L0: 什么都不装 -> T1 clang 能不能起来
# **判据不能只看退出码。** 头一版写的是 `rc < 126`，理由是「126/127 才算跑不
# 起来」—— 那对静态二进制成立，对**动态链接**的不成立：glibc 太老时
# ld.so 打一句 `version GLIBC_2.38 not found` 然后退 **1**，而 1 < 126，
# 于是 22.04 和 debian:12 上明明起不来的 clang 被判成了 ok，
# 连最后那张结论表都印着 T1=ok。**又是失败和成功共用一个退出码。**
# 改成看它有没有真打出版本号 —— 那是「跑起来了」的直接痕迹。
e=$("$CLANG" --version 2>&1); rc=$?
case "$e" in
  *"clang version"*) mark T1 "ok $(echo "$e" | head -1)" ;;
  *) mark T1 "fail rc=$rc $(echo "$e" | head -2 | tr '\n' ' ')"; exit 0 ;;
esac

# ---- L1: + make -> T2 ndk-build
apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq make >/dev/null 2>&1 \
  || { mark L1 "fail apt 装不上 make（没网？）"; exit 0; }
mark L1 ok
P=/tmp/p; mkdir -p $P/jni
printf 'int twenty(void){return 20;}\n' > $P/jni/x.c
printf 'LOCAL_PATH := $(call my-dir)\ninclude $(CLEAR_VARS)\nLOCAL_MODULE := x\nLOCAL_SRC_FILES := x.c\ninclude $(BUILD_SHARED_LIBRARY)\n' > $P/jni/Android.mk
e=$(cd $P && ANDROID_NDK_HOME=$NDK "$NDK/ndk-build" NDK_PROJECT_PATH=$P APP_ABI=arm64-v8a NDK_APPLICATION_MK=/dev/null 2>&1)
if [ -f $P/libs/arm64-v8a/libx.so ]; then mark T2 "ok $(stat -c%s $P/libs/arm64-v8a/libx.so) 字节"
else mark T2 "fail $(echo "$e" | tail -3 | tr '\n' ' ')"; exit 0; fi

# ---- L2: + JDK + zip + curl/unzip
# file(1) 也在这里装：tests/hello-native/build.sh 用它判产物架构。
# 头一版漏了，于是 24.04 上一路绿到 T3，然后挂在 `file: command not found` ——
# **挂的不是产品，是我们自己的测试缺依赖**，但报出来长得像产品坏了。
apt-get install -y -qq default-jdk-headless zip curl unzip file >/dev/null 2>&1 \
  || { mark L2 "fail apt 装不上 JDK/zip/curl/unzip/file"; exit 0; }
mark L2 "ok $(javac -version 2>&1)"

# ---- L3: platforms/android-XX —— **SDK 包有意不含它**
# make-dist.sh 的理由是「纯 Java + 数据，跟架构无关，用户手上那份直接能用」。
# 那句话对「手上已经有 SDK」的人成立，**对干净机器完全不成立** —— 这里没有
# 「手上那份」。这一层就是为了把这个门槛测出来：它是「用这个包还需要什么」
# 清单里最容易漏的一项，漏了的话用户解压完发现编不了 APK。
if ls /sdk/platforms/*/android.jar >/dev/null 2>&1; then
  mark L3 "ok 包里已经带了 platform"
else
  if curl -fsSL -o /tmp/p.zip https://dl.google.com/android/repository/platform-36_r02.zip \
     && mkdir -p /sdk/platforms && unzip -q /tmp/p.zip -d /sdk/platforms \
     && ls /sdk/platforms/*/android.jar >/dev/null 2>&1; then
    mark L3 "ok 自己下了 platform-36_r02.zip（65 MB，无 host-os 限制，任何架构通用）"
  else
    mark L3 "fail 下不下来 platform —— 没有 android.jar 就编不出 APK"; exit 0
  fi
fi
cp -a /pkg/tests /tests
e=$(ANDROID_HOME=/sdk ANDROID_NDK_HOME=$NDK bash /tests/hello-native/build.sh 2>&1)
if [ -f /tests/hello-native/build/app.apk ]; then
  mark T3 "ok APK $(stat -c%s /tests/hello-native/build/app.apk) 字节"
else
  mark T3 "fail $(echo "$e" | tail -4 | tr '\n' ' ')"
fi
INNER
# 写完先自检一下语法 —— 不然错要等到容器里才报，而且报得莫名其妙
bash -n "$PKGDIR/inner.sh" || die "容器里那段脚本语法就不对，先修它"

RESULT=""
for img in $IMAGES; do
  step "  --- $img ---"
  out=$(docker run --rm --network host -v "$PKGDIR":/pkg:ro "$img" bash /pkg/inner.sh 2>&1)
  rc=$?
  # 容器本身没起来 / 拉不到镜像 —— 那是「没测到」，不是「测出来不行」。
  # 别让它跟「跑了但失败」印成同一个样子。
  if [ $rc -ne 0 ] || ! grep -q '^@@MARK ' <<<"$out"; then
    warn "$img 没测到（rc=$rc，一条 @@MARK 都没回来）"
    printf '%s' "$out" | head -3 | sed 's/^/      /'
    RESULT="$RESULT
$img|**没测到**（容器没起来或者镜像拉不下来）"
    continue
  fi
  line=""
  for k in UNPACK T1 L1 T2 L2 L3 T3; do
    v=$(printf '%s' "$out" | sed -n "s/^@@MARK $k //p" | head -1)
    [ -n "$v" ] || v="（没走到）"
    case "$v" in ok*) printf '    \033[32m✓\033[0m %-7s %s\n' "$k" "${v#ok }" ;;
                 fail*) printf '    \033[31m✗\033[0m %-7s %s\n' "$k" "${v#fail }" ;;
                 *) printf '      %-7s %s\n' "$k" "$v" ;; esac
    # 只留状态词，别按字节截 —— cut -c 会把中文截成半个字
    case "$v" in ok*) st=ok ;; fail*) st=FAIL ;; *) st=- ;; esac
    line="$line $k=$st"
  done
  RESULT="$RESULT
$img|$line"
done

step "四、结论"
printf '%s\n' "$RESULT" | grep -v '^$' | while IFS='|' read -r i r; do note "$i  $r"; done
note ""
note "T3 绿的那些镜像 = 这个包在那上面能从零编出 APK，除了表里 L1/L2 装的那几样"
note "什么都不用。T1 就红的镜像 = glibc 太老，二进制根本起不来（看第二节的门槛）。"

fi
