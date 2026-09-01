#!/usr/bin/env bash
# 换一个 NDK 版本重建工具链 —— 把「改三处常量、别记错」变成一条命令。
#
# ---------------------------------------------------------------------------
# **为什么要有这个**
#
# 我们编的 clang 必须跟目标 NDK 自带那份**同版本**：sysroot/ 和 lib/clang/<ver>/
# 是从官方 NDK 拷进来的，版本对不上就是编译期和运行期的错配。
# 所以换 NDK 版本要同时改 LLVM_BRANCH / NDK_CLANG_VER / NDK_CLANG_REV —— 手改三处
# 常量，迟早错一处，而且错了要到编完 88 分钟之后才看得出来。
#
# 这个脚本不猜：**去读目标 NDK 自己的 toolchains/llvm/prebuilt/*/AndroidVersion.txt**
# （里面就写着 clang 版本和 based on rXXXXXX<letter>），据此推出 LLVM 分支名，
# 并且**去上游确认那个分支真的存在**再往下走。
#
# 用法：
#   tools/build-ndk-version.sh --ndk /path/to/官方NDK          # 已经下好了
#   tools/build-ndk-version.sh 28.2.13676358                  # 让它去 Google 下
#   tools/build-ndk-version.sh --ndk /path/to/NDK --dry-run    # 只推导，不编
#
# 退出码：0 成功 / 1 失败 / 2 缺前提
set -uo pipefail

die()  { printf '\n  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }
need() { printf '\n  \033[31m✗\033[0m %s\n' "$1" >&2; exit 2; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK="${WORK:-$REPO/work}"
LLVM_URL=https://android.googlesource.com/toolchain/llvm-project

NDK_PATH=""; NDK_VER=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --ndk) NDK_PATH="${2:-}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) die "不认识的参数：$1" ;;
    *) NDK_VER="$1"; shift ;;
  esac
done
[ -n "$NDK_PATH" ] || [ -n "$NDK_VER" ] || need "要么 --ndk <路径>，要么给一个版本号"

if [ -z "$NDK_PATH" ]; then
  step "从 Google 取 NDK $NDK_VER"
  command -v curl >/dev/null || need "要 curl"
  command -v unzip >/dev/null || need "要 unzip"
  d="$WORK/ndk-src"; mkdir -p "$d"; rm -rf "$d/x"
  # 解析+下载在 tools/fetch-google-package.sh 里，全仓一份。
  "$REPO/tools/fetch-google-package.sh" "ndk;$NDK_VER" "$d/x" \
    || die "取 ndk;$NDK_VER 失败 —— 版本号写对了吗？
    看有哪些：curl -s https://dl.google.com/android/repository/repository2-3.xml | grep -o 'ndk;[0-9.]*' | sort -u"
  NDK_PATH=$(ls -d "$d"/x/*/ | head -1); NDK_PATH="${NDK_PATH%/}"
  ok "解到 $NDK_PATH"
fi

step "读目标 NDK 自己记的 clang 版本"
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
step "确认上游真有这个分支"
# **推出来的名字要去上游验，别假定规则永远成立。**
_ls=$(git ls-remote --heads "$LLVM_URL" "$branch" 2>/dev/null)   # 不走管道
if case "$_ls" in *"refs/heads/$branch"*) true ;; *) false ;; esac; then
  ok "$branch 存在"
else
  die "上游没有分支 $branch（从 $rev 推的）。
    命名规则可能变了。自己看有哪些：
      git ls-remote --heads $LLVM_URL 'llvm-r*' | tail"
fi

step "这次要用的三个值"
note "LLVM_BRANCH=$branch"
note "NDK_CLANG_VER=$ver"
note "NDK_CLANG_REV=$rev"
note ""
note "（写死在 tools/build-llvm.sh 里的默认值是 llvm-r522817 / 18.0.2 / r522817b，"
note "  也就是 NDK r27.1；上面这三个会用环境变量覆盖掉它。）"

if [ "$DRY" = 1 ]; then
  step "--dry-run：到此为止"
  note "要真编就去掉 --dry-run。下面这几步会跑："
  note "  1. tools/build-in-container.sh tools/build-python.sh --build   （几分钟）"
  note "  2. tools/build-in-container.sh tools/build-llvm.sh   --build   （实测 88 分钟）"
  note "  3. tools/patch-ndk.sh <ndk> ；tools/make-ndk-dist.sh --ours-only <ndk>"
  exit 0
fi

step "编（顺序要紧：python 在前，llvm 会把它一并装进去）"
# **产物按版本分开放**，不然新版本会把现在在发的那套 rm -rf 掉。
# 源码目录由 build-llvm.sh 按分支自动分开。
export ANDROID_NDK_HOME="$NDK_PATH" LLVM_BRANCH="$branch" NDK_CLANG_VER="$ver" NDK_CLANG_REV="$rev"
export LLVM_OUT="$WORK/out/llvm-${branch#llvm-}/linux-aarch64"
export PYTHON_OUT="$WORK/out/python3-${branch#llvm-}/linux-aarch64"
export LLVM_PIN=auto
note "产物放到 $LLVM_OUT（现有的 $WORK/out/llvm 不动）"
# **不带 --build**：那只编不取，而新版本换了 LLVM 分支、源码根本还没取下来
# （第一次跑就栽在这儿：「找不到源码，先跑 --fetch」）。不带参数是
# 取 + 编 + 验三步全做，顺便白拿一轮验收。
"$REPO/tools/build-in-container.sh" "$REPO/tools/build-python.sh" || die "python 那步失败"
"$REPO/tools/build-in-container.sh" "$REPO/tools/build-llvm.sh"   || die "LLVM 那步失败"
ok "工具链编完，在 $WORK/out/llvm/linux-aarch64"

step "接下来"
note "把工具链装进那份 NDK 再打包（跟 27.1 那次一样的两步）："
note "  rm -rf $NDK_PATH/toolchains/llvm/prebuilt/linux-aarch64"
note "  cp -a $WORK/out/llvm/linux-aarch64 $NDK_PATH/toolchains/llvm/prebuilt/"
note "  $REPO/tools/patch-ndk.sh $NDK_PATH"
note "  WORK=$WORK $REPO/tools/make-ndk-dist.sh --ours-only $NDK_PATH"
