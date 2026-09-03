#!/usr/bin/env bash
# 从一份 NDK 里读出「该编哪条 LLVM 分支」，打印三行 KEY=VALUE：
#     LLVM_BRANCH=llvm-rXXXXXX
#     NDK_CLANG_VER=X.Y.Z
#     NDK_CLANG_REV=rXXXXXXx
#
# 为什么必须有这一步：build-llvm.sh 的默认值**写死是 r27.1**
# （llvm-r522817 / 18.0.2 / r522817b）。换个 NDK 版本却不换这三个值，编出来的
# 是**上一个版本的 clang**，而包装出去看不出来。
#
# 更要命的是安全网的方向：build-llvm.sh 里那条版本交叉核对，在
# ALLOW_CLANG_VER_SKEW=1 时会被压掉 —— 而 r28 恰恰必须开这个开关才能编
# （它声明 19.0.1，分支 tip 已经走到 19.0.2）。**开关一开，核对就不拦了**，
# 于是「用 r27 的 clang 打了个 r28 的包」这种事没人会发现。
# 所以别指望核对兜底：一开始就把三个值算对。
#
# 用法：
#   eval "$(tools/resolve-llvm-pin.sh /path/to/ndk)"
#   tools/resolve-llvm-pin.sh /path/to/ndk --quiet   # 不往 stderr 打说明
set -uo pipefail
LLVM_URL="${LLVM_URL:-https://android.googlesource.com/toolchain/llvm-project}"
die() { printf '\n  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }
note() { [ "${QUIET:-0}" = 1 ] || printf '    %s\n' "$1" >&2; }

NDK_PATH="${1:-}"; [ -n "$NDK_PATH" ] || die "用法：tools/resolve-llvm-pin.sh <NDK 路径>"
[ "${2:-}" = --quiet ] && QUIET=1
[ -d "$NDK_PATH" ] || die "$NDK_PATH 不在"

# **不猜，读它自己写的那个文件。** 官方包里是 linux-x86_64；我们自己打的包里
# 是 linux-aarch64 —— 两个都认，谁在就读谁。
av=""
for c in "$NDK_PATH"/toolchains/llvm/prebuilt/*/AndroidVersion.txt; do [ -f "$c" ] && { av="$c"; break; }; done
[ -n "$av" ] || die "找不到 AndroidVersion.txt（$NDK_PATH 是一份完整的 NDK 吗？）"
ver=$(sed -n '1p' "$av" | tr -d ' \r')
rev=$(sed -n '2p' "$av" | grep -oE 'r[0-9]+[a-z]*' | head -1)
[ -n "$ver" ] && [ -n "$rev" ] || die "$av 的格式不认识：
$(head -3 "$av" | sed 's/^/      /')"
note "AndroidVersion.txt  clang $ver，based on $rev"

# 分支名去掉修订号末尾那个字母：r522817b -> llvm-r522817
branch="llvm-$(printf '%s' "$rev" | sed 's/[a-z]*$//')"

# **推出来的名字要去上游验，别假定规则永远成立。**
_ls=$(git ls-remote --heads "$LLVM_URL" "$branch" 2>/dev/null)   # 不走管道
case "$_ls" in
  *"refs/heads/$branch"*) note "上游确实有 $branch" ;;
  *) die "上游没有分支 $branch（从 $rev 推的）。命名规则可能变了。自己看有哪些：
      git ls-remote --heads $LLVM_URL 'llvm-r*' | tail" ;;
esac

# **LLVM_PIN 也得跟着换。** build-llvm.sh 里钉死的那个提交号属于它默认的那条
# 分支（r27.1）；拿它去别的分支上取，两分钟就失败 —— run #6 就是这么红的。
# build-ndk-version.sh 一直显式设 LLVM_PIN=auto，而 CI 那条路没有。
#
# 规则：分支跟 build-llvm.sh 的默认值一致，就沿用它钉死的提交（那是记录在案、
# 验过黄金值的）；不一致就 auto（编分支 tip），因为**新版本该钉哪个提交，
# 在编出来、对过版本串之前根本不知道**。
default_branch=$(sed -n 's/^LLVM_BRANCH="${LLVM_BRANCH:-\(.*\)}"$/\1/p' \
                 "$(dirname "${BASH_SOURCE[0]}")/build-llvm.sh" | head -1)
if [ -n "$default_branch" ] && [ "$branch" != "$default_branch" ]; then
  note "分支不是 build-llvm.sh 的默认值（$default_branch）-> LLVM_PIN=auto"
  pin_line="LLVM_PIN=auto"
else
  pin_line=""
fi

printf 'LLVM_BRANCH=%s\nNDK_CLANG_VER=%s\nNDK_CLANG_REV=%s\n' "$branch" "$ver" "$rev"
[ -n "$pin_line" ] && printf '%s\n' "$pin_line"
exit 0
