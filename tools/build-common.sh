# 被 tools/build-<工具>.sh source，不单独执行。
#
# 放在这里的是「每个工具都要做一遍」的部分：找源码树、核对 tag、找 NDK、
# 把目标定义装进上游的树、cmake 配置、ninja、strip、取产物、决定怎么跑产物。
# **各工具自己的取源码和验收留在各自的脚本里** —— 那两块才是每个工具真正
# 不一样的地方，抽到这里只会让它们互相将就。
#
# 抽出来的直接原因：cmake 那组 flag 必须几个工具逐字一致（同一个 build 目录，
# 配置一变就全树重编）。原来每个脚本一份，注释里写着「改这里就要同步改那两个」
# —— 那句话本身就是该抽的信号。
#
# 工具脚本这样用：
#
#     TOOL=zipalign                  # 决定产物名 $WORK/out/<TOOL> 和提示语
#     CMAKE_FILES=(zipalign)         # 要装进上游树的 cmake/<名>.cmake，按 include 顺序
#     NINJA_TARGET=zipalign          # ninja 编哪个目标
#     MIN_SIZE=200000                # 验收时的体积下限，小于它直接判失败
#     . "$(dirname "${BASH_SOURCE[0]}")/build-common.sh" "$@"
#
#     [ "$DO_FETCH"  = 1 ] && { common_need_src; common_check_pin; ... }
#     [ "$DO_BUILD"  = 1 ] && common_build
#     [ "$DO_VERIFY" = 1 ] && { common_verify_prelude; ...; common_verify_done; }

set -uo pipefail

: "${TOOL:?工具脚本必须先设 TOOL}"
: "${NINJA_TARGET:=$TOOL}"
# 产物文件名默认跟目标名一样。**aapt2 是个例外**：上游的 cmake 给它的输出名带
# ABI 后缀（bin/aapt2-arm64-v8a），按目标名去找会找不到 —— 这是把公共骨架抽出来
# 之后才暴露的，老的 build-aapt2.sh 里本来有特判。
: "${BIN_NAME:=$NINJA_TARGET}"
: "${MIN_SIZE:=200000}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$REPO/work}"
SRC="$WORK/aapt2"          # 上游源码树，由 build-aapt2.sh 取，几个工具共用
OUT="$WORK/out/$TOOL"      # 产物。跟 SRC 分开 —— 撞名的教训见 build-aapt2.sh
PROTOC="$WORK/protoc/bin/protoc"

# 上游子模块 pin 的 tag。不是抄来的，是拿上游实际 pin 的 commit 跟 AOSP 的 tag
# 对出来的，common_check_pin 每次 --fetch 会重对一遍。
AOSP_TAG=platform-tools-35.0.2
GOOGLESOURCE=https://android.googlesource.com/platform

die()  { printf '\n  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1" >&2; }

# file(1) 是硬依赖：下面用 `case "$(file -b …)" in *ELF*)` 当闸门的地方，
# file 一缺就是空串 -> 全部 continue -> 检查空转报绿。实测过（见 docs/zh/LESSONS.md）。
command -v file >/dev/null || die "要 file(1)：sudo apt install -y file
    这个脚本靠它认二进制架构，缺了检查会静默空转。"

# 默认盯哪个 NDK。**放在这里是为了让 CI 有个单一出处** —— smoke-build.yml 以前
# 把 android-ndk-r27b-linux.zip 写死在 curl 里，tools/ 这边版本往前走了 CI 也
# 不会跟着变，会一直拿旧 NDK 编。改版本只改这一行。
# 各构建脚本本身不读它（它们从 ANDROID_NDK_HOME / $ANDROID_HOME/ndk 发现 NDK），
# 这个值是给 CI 和 tools/fetch-google-package.sh 用的。
# 为什么是 27.1 而不是最新的 r27：见 docs/VERSIONS.md（React Native 钉的是它）。
NDK_DEFAULT_VER=27.1.12297006

# 开头就把**这个脚本自己**是哪一版打出来。
# 起因：会话里三次「贴了命令但漏了 git pull」，拿旧配方跑了一两个小时，
# 而输出看上去一切正常。产物的对错追到最后总要先回答「你跑的是哪一版」，
# 那就让它自己说，别每次靠人去查。
# 两个都打：工具脚本自己，和这个公共骨架 —— 那组必须逐字一致的 cmake flag
# 在骨架里，它的版本一样要紧。
# 用 $0 不用 BASH_SOURCE：在被 source 的文件顶层，BASH_SOURCE 指的是自己。
common_print_rev() {
  local f r
  for f in "$0" "${BASH_SOURCE[0]}"; do
    r=$(git -C "$REPO" log -1 --format='%h %ad' --date=short -- "$f" 2>/dev/null)
    printf '  \033[2m%s @ %s\033[0m\n' "$(basename "$f")" "${r:-（不在 git 里）}"
  done
}
common_print_rev

DO_FETCH=1 DO_BUILD=1 DO_VERIFY=1
case "${1:-}" in
  --fetch)  DO_BUILD=0; DO_VERIFY=0 ;;
  --build)  DO_FETCH=0; DO_VERIFY=0 ;;
  --verify) DO_FETCH=0; DO_BUILD=0 ;;
  "") ;;
  *) die "不认识的参数：$1" ;;
esac

common_need_src() {
  [ -d "$SRC/cmake" ] && [ -d "$SRC/submodules/libbase" ] || die \
"找不到上游源码树 $SRC。

    这些工具共用这棵树（libbase / libutils / libandroidfw 都在里面），
    先跑：

        tools/build-aapt2.sh --fetch"
}

# 每个工具都要 protoc，哪怕它跟 protobuf 一点关系没有：cmake 配置的是**整个工程**，
# cmake/aapt2.cmake 在配置阶段就要 protoc，找不到直接 FATAL_ERROR。实测过：
#     CMake Error at cmake/aapt2.cmake:11 (message):
#       Invalid protoc: Protobuf_PROTOC_EXECUTABLE-NOTFOUND
common_need_protoc() {
  [ -x "$PROTOC" ] || die \
"找不到 protoc（$PROTOC）。$TOOL 用不到它，但整个工程配置不过去就什么都编不了。
    下载它的是：tools/build-aapt2.sh --fetch"
}

# 另取的源码树必须跟上游子模块是同一版，否则等于拿这个版本的工具去链别的版本的库。
# 对法：拿上游 pin 的 libbase commit，跟该仓库 $AOSP_TAG 解出来的 commit 比。
common_check_pin() {
  local pinned tagged
  pinned=$(git -C "$SRC" ls-tree HEAD submodules/libbase 2>/dev/null | awk '{print $3}')
  tagged=$(git ls-remote "$GOOGLESOURCE/system/libbase" "refs/tags/$AOSP_TAG^{}" 2>/dev/null | awk '{print $1}')
  if [ -z "$tagged" ]; then
    warn "连不上 googlesource，跳过 tag 核对（离线？）"
  elif [ -z "$pinned" ]; then
    warn "读不出上游 pin 的 libbase commit，跳过 tag 核对"
  elif [ "$pinned" = "$tagged" ]; then
    ok "tag 核对通过：上游子模块 pin 的就是 $AOSP_TAG"
  else
    note "上游 pin  $pinned"
    note "$AOSP_TAG  $tagged"
    if [ "${ALLOW_TAG_MISMATCH:-0}" = 1 ]; then
      warn "对不上，但 ALLOW_TAG_MISMATCH=1，继续。"
    else
      die "上游子模块的版本跟 AOSP_TAG=$AOSP_TAG 对不上了。

    多半是上游把子模块升到了新的 platform-tools 版本。**别硬编** ——
    混版本编出来的东西不知道是什么。改法：把 tools/build-common.sh 里的
    AOSP_TAG 改成上游现在 pin 的那个版本，重跑。确认上游 pin 的是哪个：

        git -C $SRC ls-tree HEAD submodules/libbase

    只想先试试：ALLOW_TAG_MISMATCH=1 tools/build-$TOOL.sh --fetch"
    fi
  fi
}

# common_fetch_tree <落到 submodules/ 下的名字> <googlesource 上的路径> <哨兵文件> [稀疏目录...]
# 给稀疏目录就只 checkout 那几个目录（platform/build 整棵几百 MB，只要 tools/zipalign；
# platform/art 更大，只要 dexdump libdexfile libartbase libartpalette 四个）。
# 多个目录用空格隔开，整体作为第 4 个参数传进来。
common_fetch_tree() {
  local name="$1" repopath="$2" sentinel="$3" sparse="${4:-}"
  local dest="$SRC/submodules/$name"
  if [ -f "$dest/$sentinel" ]; then
    note "submodules/$name 已存在，跳过"
  else
    rm -rf "$dest"
    if [ -n "$sparse" ]; then
      git clone --depth 1 --filter=blob:none --sparse --branch "$AOSP_TAG" \
          -c advice.detachedHead=false "$GOOGLESOURCE/$repopath" "$dest" \
        || die "clone $repopath 失败"
      # 故意不加引号：$sparse 可能是空格分开的多个目录
      # shellcheck disable=SC2086
      git -C "$dest" sparse-checkout set $sparse || die "sparse-checkout $sparse 失败"
    else
      git clone --depth 1 --branch "$AOSP_TAG" -c advice.detachedHead=false \
          "$GOOGLESOURCE/$repopath" "$dest" || die "clone $repopath 失败"
    fi
  fi
  [ -f "$dest/$sentinel" ] || die "取下来了但 $sentinel 不在 —— 这个版本挪窝了？"
  ok "$name $(du -sh "$dest" 2>/dev/null | cut -f1)"
}

common_find_ndk() {
  NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK:-}}"
  if [ -z "$NDK" ]; then
    for d in "${ANDROID_HOME:-}"/ndk/*/; do NDK="${d%/}"; done
  fi
  [ -n "$NDK" ] && [ -d "$NDK/build/cmake" ] || die "找不到 NDK"
  HOST_TAG="linux-$(uname -m)"
  [ "$(uname -m)" = arm64 ] && HOST_TAG=linux-aarch64
  [ -x "$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin/clang" ] \
    || die "$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin/clang 不在。
    先跑 tools/make-shim-toolchain.sh（并确认 tools/patch-ndk.sh 打过了）。"
}

common_build() {
  common_need_src
  common_need_protoc
  common_find_ndk
  command -v cmake >/dev/null || die "没有 cmake：sudo apt install -y cmake"
  command -v ninja >/dev/null || die "没有 ninja：sudo apt install -y ninja-build"

  step "把 $TOOL 的目标定义装进上游的树"
  local f
  for f in "${CMAKE_FILES[@]}"; do
    cp "$REPO/cmake/$f.cmake" "$SRC/cmake/$f.cmake" || die "拷 $f.cmake 失败"
    if grep -q "^include($f.cmake)" "$SRC/cmake/CMakeLists.txt"; then
      note "cmake/CMakeLists.txt 已经 include 过 $f.cmake"
    else
      printf '\ninclude(%s.cmake)\n' "$f" >> "$SRC/cmake/CMakeLists.txt"
    fi
  done
  ok "${CMAKE_FILES[*]} + include（重复跑不会叠加）"

  # 上游的 patch.sh 必须跑过：它把 misc/IncrementalProperties.sysprop.cpp 拷进
  # submodules/incremental_delivery/，而 cmake/libincfs.cmake 把那个文件列成源文件。
  # 少了它 **cmake 配置阶段**就报「找不到源文件」，跟本工具无关但全树都编不了。
  step "打上游的补丁"
  ( cd "$SRC" && ./patch.sh ) >/dev/null 2>&1
  ok "patch.sh 跑完（重复跑会报已打过，不影响）"

  step "cmake 配置"
  note "NDK       $NDK"
  note "host tag  $HOST_TAG"
  note "protoc    $PROTOC"
  # 这组 flag 抄自上游 build.sh，加了两个 -D（protoc 路径、-lc++abi）。
  # **几个工具必须逐字一致** —— 同一个 build 目录，配置一变就全树重编。
  # 这也是把它抽到 build-common.sh 的直接原因。
  ( cd "$SRC" && cmake -GNinja -B build \
      -DANDROID_NDK="$NDK" \
      -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
      -DANDROID_PLATFORM=android-30 \
      -DCMAKE_ANDROID_ARCH_ABI=arm64-v8a \
      -DANDROID_ABI=arm64-v8a \
      -DCMAKE_SYSTEM_NAME=Android \
      -DANDROID_ARM_NEON=ON \
      -DCMAKE_BUILD_TYPE=Release \
      -DPNG_SHARED=OFF \
      -DZLIB_USE_STATIC_LIBS=ON \
      -DProtobuf_PROTOC_EXECUTABLE="$PROTOC" \
      -DCMAKE_CXX_STANDARD_LIBRARIES="-latomic -lm -lc++abi" ) || die "cmake 配置失败"
  ok "配置完成"

  step "ninja $NINJA_TARGET（$(nproc) 核）"
  ( cd "$SRC" && ninja -C build "$NINJA_TARGET" ) || die "编译失败"

  local bin
  bin=$(find "$SRC/build" -type f -name "$BIN_NAME" -perm -u+x 2>/dev/null | head -1)
  [ -n "$bin" ] && [ -f "$bin" ] || die "编完了但找不到产物，去 $SRC/build/bin 底下看看"

  local strip_bin= c before
  for c in llvm-strip llvm-strip-18 \
           "$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin/llvm-strip"; do
    command -v "$c" >/dev/null 2>&1 && { strip_bin="$c"; break; }
    [ -x "$c" ] && { strip_bin="$c"; break; }
  done
  if [ -n "$strip_bin" ]; then
    before=$(stat -c%s "$bin")
    "$strip_bin" --strip-unneeded "$bin" && ok "strip：$before -> $(stat -c%s "$bin") 字节"
  else
    note "没找到 llvm-strip，跳过（只是体积大些）"
  fi
  mkdir -p "$(dirname "$OUT")"
  cp "$bin" "$OUT"
  ok "产物 $OUT（$(stat -c%s "$OUT") 字节）"
}

# 验收的开头：体积、架构、决定怎么跑它。非 aarch64 且没开 ALLOW_QEMU 时**直接退出**，
# 后面那些测试根本跑不了。跑得了的话定义 run_tool 供各脚本调用。
common_verify_prelude() {
  BIN="$OUT"
  [ -f "$BIN" ] || die "$BIN 不在，先编出来"

  step "验自己编的这个 $TOOL"
  local sz; sz=$(stat -c%s "$BIN")
  # 荒谬值要当场报错，别照着印 —— build-aapt2.sh 那个「4096 字节」的教训。
  [ "$sz" -gt "$MIN_SIZE" ] || die "$BIN 只有 $sz 字节 —— 静态 $TOOL 不可能这么小，取产物那步出错了"
  note "$(file -b "$BIN")"
  case "$(file -b "$BIN")" in
    *"ARM aarch64"*) ;;
    *) die "不是 aarch64" ;;
  esac
  ok "是 aarch64，$sz 字节"

  RUNNER=""
  QEMU_NOTE=0
  if [ "$(uname -m)" != aarch64 ] && [ "$(uname -m)" != arm64 ]; then
    if [ "${ALLOW_QEMU:-0}" = 1 ] && command -v qemu-aarch64-static >/dev/null 2>&1; then
      RUNNER=qemu-aarch64-static
      QEMU_NOTE=1
      warn "在 $(uname -m) 上用 qemu 跑。**这不是验收** —— 第五节第 1 条。
    它能告诉你下面这几条测试本身写对没有，告诉不了你产物在真机上对不对：
    它模拟的是指令，不是那台机器的内核、libc 加载路径和文件系统。"
    else
      step "这台是 $(uname -m)，跑不了它"
      note "已验：目标定义对、源码编得过、符号链得上、产物是 aarch64、体积合理。"
      note "**没验**：它跑起来对不对。第五节第 1 条 —— 拿到 ARM64 机器上跑："
      note "    tools/build-$TOOL.sh --verify"
      note ""
      note "只想先确认那几条测试本身没写错（不是验收）："
      note "    ALLOW_QEMU=1 tools/build-$TOOL.sh --verify   # 需要 qemu-user-static"
      exit 0
    fi
  fi
}

# 统一入口，省得每处都判一次 RUNNER。
#   run_tool  ...        跑本工具的产物
#   run_bin <路径> ...   跑别的 aarch64 产物（比如交叉验证时换 aapt2 读同一个 APK）
run_bin()  { local b="$1"; shift; if [ -n "$RUNNER" ]; then "$RUNNER" "$b" "$@"; else "$b" "$@"; fi; }
run_tool() { run_bin "$BIN" "$@"; }

# $1 = 全绿时打印的用法提示（可空）
common_verify_done() {
  if [ "$QEMU_NOTE" = 1 ]; then
    step "测试在 qemu 下都过了 —— 说明测试本身没写错"
    warn "**这不算验收。** 产物有没有问题，要在真 ARM64 机器上重跑这条命令才知道。"
  else
    step "这份 $TOOL 是自己编的，可以用了"
    [ -n "${1:-}" ] && echo "$1"
  fi
}
