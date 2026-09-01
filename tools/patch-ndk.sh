#!/usr/bin/env bash
# 把 patches/ndk/ 底下的补丁打到一个已安装的 NDK 上。
#
# 这些补丁只让 NDK「认得」linux-aarch64 这个 host tag。它们**不**产出
# toolchains/llvm/prebuilt/linux-aarch64/ 底下的东西——那是 M1 的活。
# 打完补丁而工具链还没编出来，你会得到一条清楚的「找不到工具链」，
# 而不是一条莫名其妙的报错。这是进步。
#
# 用法：
#   tools/patch-ndk.sh [--check|--revert] [ndk 路径]
#
#   --check    只报告状态，不动文件
#   --revert   撤销
#   ndk 路径   不给就从 $ANDROID_NDK_HOME / $ANDROID_NDK / $ANDROID_HOME/ndk/* 找
#
# 退出码：0 成功（或 --check 下「全部已打」）；1 失败或状态不干净

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHDIR="$HERE/../patches/ndk"

MODE=apply
case "${1:-}" in
  --check)  MODE=check;  shift ;;
  --revert) MODE=revert; shift ;;
  --help|-h) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  -*) echo "不认识的参数：$1"; exit 1 ;;
esac

command -v patch >/dev/null || { echo "需要 patch 命令（Debian/Ubuntu: apt install patch）"; exit 1; }

# ---- 找 NDK ----
NDK="${1:-}"
if [ -z "$NDK" ]; then
  for c in "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK:-}" \
           "${ANDROID_HOME:-}"/ndk/* "${ANDROID_SDK_ROOT:-}"/ndk/* \
           "${ANDROID_HOME:-}"/ndk-bundle; do
    if [ -n "$c" ] && [ -d "$c/build/cmake" ]; then NDK="$c"; break; fi
  done
fi
if [ -z "$NDK" ] || [ ! -d "$NDK/build/cmake" ]; then
  echo "没找到 NDK。传路径：tools/patch-ndk.sh /path/to/ndk"
  exit 1
fi
NDK="$(cd "$NDK" && pwd)"

ver="未知"
[ -f "$NDK/source.properties" ] && \
  ver=$(grep -E '^Pkg.Revision' "$NDK/source.properties" | cut -d= -f2 | tr -d ' ')
echo "NDK: $NDK"
echo "版本: $ver"
echo

patches=$(find "$PATCHDIR" -name '*.patch' | sort)
[ -n "$patches" ] || { echo "$PATCHDIR 底下没有补丁"; exit 1; }

rc=0
applied=0; pending=0; broken=0

for p in $patches; do
  name=$(basename "$p")

  # -R --dry-run 能过 = 已经打过了
  if patch -d "$NDK" -p1 -R --dry-run --silent < "$p" >/dev/null 2>&1; then
    state=applied
  elif patch -d "$NDK" -p1 --dry-run --silent < "$p" >/dev/null 2>&1; then
    state=pending
  else
    state=broken
  fi

  case "$MODE:$state" in
    check:applied|apply:applied)
      printf '  \033[32m已打\033[0m    %s\n' "$name"; applied=$((applied+1)) ;;

    check:pending)
      printf '  \033[33m未打\033[0m    %s\n' "$name"; pending=$((pending+1)); rc=1 ;;

    apply:pending)
      if patch -d "$NDK" -p1 --silent < "$p"; then
        printf '  \033[32m打上\033[0m    %s\n' "$name"; applied=$((applied+1))
      else
        printf '  \033[31m失败\033[0m    %s\n' "$name"; broken=$((broken+1)); rc=1
      fi ;;

    revert:applied)
      if patch -d "$NDK" -p1 -R --silent < "$p"; then
        printf '  \033[32m撤销\033[0m    %s\n' "$name"
      else
        printf '  \033[31m撤销失败\033[0m %s\n' "$name"; rc=1
      fi ;;

    revert:pending)
      printf '  \033[36m本来就没打\033[0m %s\n' "$name" ;;

    *:broken)
      printf '  \033[31m对不上\033[0m  %s\n' "$name"
      printf '           这个 NDK（%s）的上下文跟补丁对不上。\n' "$ver"
      printf '           多半是 NDK 升级了行号或上下文变了——需要把补丁 rebase 到新版本。\n'
      printf '           见 patches/ndk/README.md。**别硬来**：打歪的 toolchain 文件\n'
      printf '           会以很难查的方式坏掉。\n'
      broken=$((broken+1)); rc=1 ;;
  esac
done

echo
if [ "$MODE" = check ]; then
  echo "已打 $applied / 未打 $pending / 对不上 $broken"
  [ "$rc" -eq 0 ] && echo "全部已打。"
elif [ "$MODE" = apply ] && [ "$rc" -eq 0 ]; then
  echo "打完了。下一步："
  echo "  tools/verify-claims.sh $NDK      # 两处 BLOCK 应该都变 PASS"
  echo
  echo "注意：这只让 NDK 认得 linux-aarch64，工具链本身还没有。"
  echo "现在去编东西，会报找不到 toolchains/llvm/prebuilt/linux-aarch64 ——那是对的。"
fi

exit $rc
