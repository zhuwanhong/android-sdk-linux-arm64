#!/usr/bin/env bash
# 把两个 release 包铺成一个**干净的 $ANDROID_HOME**，给下游工程用。
#
# ---------------------------------------------------------------------------
# **这个脚本存在的理由是把两件事分开**：
#
#   开发环境（这个仓库）   源码树、构建树、官方 x86_64 NDK（当输入）、
#                          对照用的 x86_64 二进制…… 这些**都不该进下游的 SDK**。
#   下游使用环境           一个 $ANDROID_HOME，里面只有 release 解出来的东西，
#                          外加跟架构无关、由 Google 自己装的那部分。
#
# 混在一起的后果不是「乱」，是**验证会失真**：开发环境里随手放着的一个
# x86_64 工具、一个 qemu，都会让「在干净机器上能不能用」这个问题得到假答案。
#
# ---------------------------------------------------------------------------
# **下游的 $ANDROID_HOME 里到底要有什么**（2026-08-29 实测出来的，不是推的）：
#
#   我们给的（两个 tar.gz）      build-tools/  platform-tools/  ndk/
#   Google 给的、跟架构无关      licenses/     platforms/
#
# 第二样**必须有，但不该由我们分发**：`platforms/android-XX/android.jar` 是纯
# Java + 数据，任何架构通用。实测只解我们两个包、不放 licenses 时，AGP 报
#
#     Failed to install the following Android SDK packages as some licences
#     have not been accepted: platforms;android-36
#
# 而**只要把 licenses/ 放进去，AGP 自己就会把 platforms 下下来**（实测：
# "Installing Android SDK Platform 36 in .../platforms/android-36"，然后端到端全绿）。
# 所以这个脚本只负责铺我们那部分 + 把 licenses 摆好，platforms 留给 AGP/sdkmanager。
#
# ---------------------------------------------------------------------------
# 用法：
#   tools/make-downstream-sdk.sh [目标目录]        默认 $HOME/Android/Sdk
#   SDK_TGZ=... NDK_TGZ=... tools/make-downstream-sdk.sh
#   LICENSES_FROM=/path/to/existing/sdk/licenses tools/make-downstream-sdk.sh
#
# **不会覆盖别人的 SDK**：目标目录已存在且不是这个脚本铺出来的（没有
# PROVENANCE.txt），就停下来让人自己决定。

set -uo pipefail

die()  { printf '\n  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1" >&2; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_rev=$(git -C "$REPO" log -1 --format='%h %ad' --date=short -- "${BASH_SOURCE[0]}" 2>/dev/null)
printf '  \033[2m%s @ %s\033[0m\n' "$(basename "${BASH_SOURCE[0]}")" "${_rev:-（不在 git 里）}"

WORK="${WORK:-$REPO/work}"
DEST="${1:-$HOME/Android/Sdk}"

pick_tgz() {  # $1=通配 $2=人话名字
  local g="$1" n="$2" f
  f=$(ls -t $g 2>/dev/null | head -1)
  [ -n "$f" ] || die "找不到$n 的 tar.gz（找的是 $g）。
    先跑 tools/make-dist.sh / tools/make-ndk-dist.sh，或者用 SDK_TGZ= / NDK_TGZ= 指过来。"
  printf '%s' "$f"
}
SDK_TGZ="${SDK_TGZ:-$(pick_tgz "$WORK/android-sdk-linux-arm64-*.tar.gz" "SDK 包")}" || exit 1
NDK_TGZ="${NDK_TGZ:-$(pick_tgz "$WORK/android-ndk-*-linux-aarch64.tar.gz" "NDK 包")}" || exit 1

step "要铺的东西"
note "SDK 包  $SDK_TGZ（$(du -h "$SDK_TGZ" | cut -f1)）"
note "NDK 包  $NDK_TGZ（$(du -h "$NDK_TGZ" | cut -f1)）"
note "铺到    $DEST"

# --------------------------------------------------------------------------
step "看一眼目标目录"
if [ -e "$DEST" ]; then
  if [ -f "$DEST/PROVENANCE.txt" ]; then
    note "$DEST 是这个脚本铺过的（有 PROVENANCE.txt），重铺"
    # 只删我们铺的那三样，**不动 licenses/ 和 platforms/** ——
    # 那是 Google 那半，重下要几分钟，而且跟架构无关，没必要跟着我们重铺。
    rm -rf "$DEST/build-tools" "$DEST/platform-tools" "$DEST/ndk" "$DEST/PROVENANCE.txt"
  elif [ -z "$(ls -A "$DEST" 2>/dev/null)" ]; then
    note "$DEST 是空目录"
  else
    die "$DEST 已经有东西了，而且不是这个脚本铺的（没有 PROVENANCE.txt）。
    **不覆盖别人的 SDK。** 自己挪开，或者换个目录：
      tools/make-downstream-sdk.sh /path/to/别的地方"
  fi
fi
mkdir -p "$DEST" || die "建不了 $DEST"

step "解包"
tar -C "$DEST" -xzf "$SDK_TGZ" || die "解 SDK 包失败"
tar -C "$DEST" -xzf "$NDK_TGZ" || die "解 NDK 包失败"
ok "build-tools / platform-tools / ndk 就位（$(du -sh "$DEST" | cut -f1)）"

# --------------------------------------------------------------------------
step "licenses（Google 那半，跟架构无关）"
if [ -f "$DEST/licenses/android-sdk-license" ]; then
  ok "已经有了"
else
  src="${LICENSES_FROM:-}"
  if [ -z "$src" ]; then
    for c in "$ANDROID_HOME/licenses" "$ANDROID_SDK_ROOT/licenses" "$HOME/Android/Sdk/licenses" /opt/android-sdk/licenses; do
      [ -n "$c" ] && [ -f "$c/android-sdk-license" ] && { src="$c"; break; }
    done
  fi
  if [ -n "$src" ]; then
    cp -a "$src" "$DEST/" || die "拷 licenses 失败"
    ok "从 $src 拷过来了"
  else
    # **「没做」和「做了」要分开说。**
    warn "没找到现成的 licenses，**这一步没做**。"
    note "下游第一次编会报 platforms;android-36 装不了。补法（二选一）："
    note "  · sdkmanager --licenses     （cmdline-tools 里的，纯 Java，ARM 上跑得动）"
    note "  · LICENSES_FROM=/别的/sdk/licenses 重跑本脚本"
  fi
fi

# --------------------------------------------------------------------------
# **判据是「真跑一次」，不是「文件在」。** 下游的契约就是这么查的。
step "验：原生件真能跑"
fail=0
run1() { # $1=路径 $2=参数
  [ -x "$1" ] || { warn "$1 不在"; fail=1; return; }
  "$1" "${2:-}" >/dev/null 2>&1
  local rc=$?
  [ $rc -lt 126 ] || { warn "$(basename "$1") 跑不起来（退出码 $rc）：$1"; fail=1; return; }
  ok "$(basename "$1")（$1）"
}
bt=""; for d in "$DEST"/build-tools/*/; do bt="${d%/}"; done
[ -n "$bt" ] || die "没有 build-tools"
run1 "$bt/aapt2" version
run1 "$bt/zipalign"
run1 "$DEST/platform-tools/adb" --version
ndk=""; for d in "$DEST"/ndk/*/; do ndk="${d%/}"; done
[ -n "$ndk" ] || die "没有 ndk"
# 下游按写死的 linux-x86_64 去找（android.toolchain.cmake 对任何 Linux 主机都
# 设 ANDROID_HOST_TAG=linux-x86_64）。包里那条兼容软链就是给这个用的。
tcbin="$ndk/toolchains/llvm/prebuilt/linux-x86_64/bin"
[ -d "$tcbin" ] || { warn "$tcbin 不在 —— 下游会报「NDK 工具链不在 linux-x86_64」"; fail=1; }
for t in clang clang++ ld.lld llvm-ar llvm-ranlib llvm-strip llvm-nm llvm-objcopy; do
  run1 "$tcbin/$t" --version
done
[ "$fail" = 0 ] || die "上面这些没过，别交给下游。"

step "好了"
note "下游这样用："
note "  export ANDROID_HOME=$DEST"
note "  export ANDROID_SDK_ROOT=\$ANDROID_HOME"
note "  export ANDROID_NDK_HOME=$ndk"
note ""
note "**包里没有、也不该有的三样**（下游自己配，理由见 docs/INSTALL.md 第三节）："
note "  1. platforms/  —— 跟架构无关，licenses 就位后 AGP 自己会下"
note "  2. cmake/ninja —— 用系统的：local.properties 写 cmake.dir=/usr"
note "     （不写的话 AGP 会自己去下一份 x86_64 的装进这个 SDK）"
note "  3. aapt2       —— gradle.properties 写"
note "     android.aapt2FromMavenOverride=$bt/aapt2"
note "     （AGP 不用 SDK 里这个，它从 maven 解析一个 x86_64 的）"
note ""
note "React Native 的工程还要第四样：hermesc。它**不在 SDK 里**，"
note "用 tools/build-hermesc.sh 编，再用 react { hermesCommand } 指过去。"
