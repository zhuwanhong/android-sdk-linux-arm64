#!/usr/bin/env bash
# 拼一棵**能在 ARM64 上真正用来交叉编译**的 NDK：官方 NDK + 我们自己编的 host
# 工具链 + host tag 补丁。
#
# 为什么需要它：
#   - 官方 NDK 的 host 工具链是 linux-x86_64，在 ARM64 上根本跑不起来；
#   - 我们发的 `-ours` NDK 包**是故意不完整的** —— sysroot 和 lib/clang 是
#     Google 分发的文件，我们不转发，由 tools/install.sh 在装的时候补回来。
#     拿 `-ours` 包直接去编东西，会因为没有头文件和目标库当场失败。
#     （CI 上真栽过：sdk-tools 那个 job 解开 -ours 包就去编，2 分钟报废。）
#
# 用法：
#   tools/prepare-ndk.sh <NDK 版本> <我们的工具链目录> <放到哪>
#     <我们的工具链目录> = build-llvm.sh 产出的 linux-aarch64 那一棵
#   成功时**最后一行打印 NDK 根目录的路径**，方便调用方拿去当 ANDROID_NDK_HOME。
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
die()  { printf '\n  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$1" >&2; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1" >&2; }

# file(1) 是硬依赖：最后一步拿它判编出来的目标文件是不是 aarch64。
command -v file >/dev/null || die "要 file(1)：sudo apt install -y file"

VER="${1:-}"; TC="${2:-}"; DEST="${3:-}"
[ -n "$VER" ] && [ -n "$TC" ] && [ -n "$DEST" ] \
  || die "用法：tools/prepare-ndk.sh <NDK 版本> <工具链目录> <放到哪>"
[ -d "$TC" ] || die "工具链目录不在：$TC"
[ -x "$TC/bin/clang" ] || die "$TC/bin/clang 不在 —— 这不像 build-llvm.sh 的产物"

step "1/4  取官方 NDK $VER"
mkdir -p "$DEST" || die "建不了 $DEST"
"$REPO/tools/fetch-google-package.sh" "ndk;$VER" "$DEST" || die "取官方 NDK 失败"
N=$(ls -d "$DEST"/*/ | head -1); N="${N%/}"
[ -d "$N/toolchains/llvm/prebuilt" ] || die "$N 看着不像 NDK"
ok "$N"

step "2/4  换上我们编的 host 工具链"
rm -rf "$N/toolchains/llvm/prebuilt/linux-aarch64"
cp -a "$TC" "$N/toolchains/llvm/prebuilt/linux-aarch64" || die "拷工具链失败"
ok "linux-aarch64 就位"

step "3/4  嫁接 sysroot 和 lib/clang"
# 这两样跟 host 架构无关（头文件 + 目标端的库），从官方那棵 x86_64 里原样拿。
X="$N/toolchains/llvm/prebuilt/linux-x86_64"; T="$N/toolchains/llvm/prebuilt/linux-aarch64"
[ -d "$X/sysroot" ] || die "官方包里没有 $X/sysroot"
rm -rf "$T/sysroot" "$T/lib/clang"
cp -a "$X/sysroot" "$T/sysroot"   || die "嫁接 sysroot 失败"
mkdir -p "$T/lib"
cp -a "$X/lib/clang" "$T/lib/clang" || die "嫁接 lib/clang 失败"
ok "sysroot $(du -sh "$T/sysroot" | cut -f1) / lib/clang $(du -sh "$T/lib/clang" | cut -f1)"

step "4/4  打 host tag 的补丁并真编一个目标文件"
"$REPO/tools/patch-ndk.sh" "$N" >&2 || die "patch-ndk.sh 失败"
# **别只看文件在不在**：真拿它编一个 aarch64-linux-android 的目标文件，
# 编不出来就说明这棵树还是不能用（sysroot 少东西的话正是在这里露馅）。
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
printf '#include <stdio.h>\nint main(void){printf("ok\\n");return 0;}\n' > "$tmp/t.c"
"$T/bin/clang" --target=aarch64-linux-android24 -c "$tmp/t.c" -o "$tmp/t.o" 2>"$tmp/err" \
  || die "拿这棵 NDK 编不出目标文件：$(tail -3 "$tmp/err")"
case "$(file -b "$tmp/t.o")" in
  *"ARM aarch64"*) ok "真编出了 aarch64 目标文件（$(stat -c%s "$tmp/t.o") 字节）" ;;
  *) die "编出来的不是 aarch64：$(file -b "$tmp/t.o")" ;;
esac

printf '%s\n' "$N"
