#!/usr/bin/env bash
# 在一个**更老的发行版**的容器里跑我们的构建脚本，好把产物的 glibc 门槛压下来。
#
# ---------------------------------------------------------------------------
# **为什么需要这个**：门槛跟着编译机走。在 Ubuntu 24.04（glibc 2.39）上编出来的
# host 二进制要 `GLIBC_2.38`，于是 22.04（2.35）和 Debian 12（2.36）上**开都
# 开不起来** —— 报 `version GLIBC_2.38 not found`，跟「缺个库」不是一回事。
# 实测见 tools/test-clean-machine.sh --docker。
#
# **只有 host 二进制受影响**，而且就三样：
#   tools/build-llvm.sh      NDK 的 host 工具链（clang / lld / llvm-*，32 个）
#   tools/build-python.sh    工具链自带的 python3
#   tools/build-hermesc.sh   hermesc
# SDK 包里那些（aapt2 / aapt / zipalign / adb / fastboot…）是**静态 bionic**，
# GLIBC 符号一个都没有，跟这件事无关，不用重编。
#
# **容器里只看得见 $REPO（只读）和 $WORK（可写）。** 所以 build-llvm.sh 要的那份
# NDK（它拿来当只读供体，拷 sysroot/ 和 lib/clang/）必须放在 $WORK 里，
# 典型是 $WORK/android-ndk-<版本>/ —— 放在 /opt 下容器根本看不到，会报
# 「找不到 NDK」。2026-08-30 实测踩过。
#
# **不追到 Google 那个 GLIBC_2.16。** 那要维护一套老 sysroot；2.35 是性价比
# 拐点 —— 覆盖 22.04、Debian 12 和所有更新的，代价只是换个容器编。
#
# ---------------------------------------------------------------------------
# 用法：
#   tools/build-in-container.sh <脚本> [参数...]
#   tools/build-in-container.sh tools/build-llvm.sh --build
#   IMAGE_BASE=debian:11 tools/build-in-container.sh tools/build-hermesc.sh
#
#   WORK=...    容器里看到的还是这个路径（原样挂进去），默认 $REPO/work
#
# 容器里以**当前用户的 uid/gid** 跑，产物不会变成 root 的。
set -uo pipefail

die()  { printf '\n  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_rev=$(git -C "$REPO" log -1 --format='%h %ad' --date=short -- "${BASH_SOURCE[0]}" 2>/dev/null)
printf '  \033[2m%s @ %s\033[0m\n' "$(basename "${BASH_SOURCE[0]}")" "${_rev:-（不在 git 里）}"

[ $# -ge 1 ] || die "要传一个脚本。例：tools/build-in-container.sh tools/build-llvm.sh --build"
WORK="${WORK:-$REPO/work}"
[ -d "$WORK" ] || die "WORK=$WORK 不在"
WORK=$(cd "$WORK" && pwd)

IMAGE_BASE="${IMAGE_BASE:-ubuntu:22.04}"
TAG="asla-build:$(echo "$IMAGE_BASE" | tr ':/' '--')"

# **判据是 docker info，不是 command -v** —— 客户端装着守护进程没跑是最常见的。
command -v docker >/dev/null || die "没有 docker：sudo apt install -y docker.io"
# 连不上守护进程时**自己退到 sudo**，别只报错让人手动折腾。
# **但只有 docker 调用走 sudo，整个脚本不能 sudo 跑** —— 下面 docker run 用
# `--user $(id -u):$(id -g)` 保证产物属主是你自己，整脚本 sudo 的话 id -u 变成 0，
# $WORK 里编出来的东西全归 root，后面 make-dist.sh 之类以普通用户跑就动不了了。
DOCKER=(docker)
if ! docker info >/dev/null 2>&1; then
  if sudo -n docker info >/dev/null 2>&1; then
    DOCKER=(sudo -n docker)
    note "当前用户连不上 docker 守护进程，改走 sudo（容器里仍以 $(id -u):$(id -g) 跑，产物属主不变）"
  else
    die "docker 守护进程连不上，sudo 也不行。
    要么把自己加进 docker 组（要重新登录才生效）：sudo usermod -aG docker \$USER
    要么让 sudo 免密。"
  fi
fi

step "准备镜像 $TAG（基于 $IMAGE_BASE）"
if "${DOCKER[@]}" image inspect "$TAG" >/dev/null 2>&1; then
  note "已经有了，跳过构建（要重建就先 docker rmi $TAG）"
else
  # 装的是那三个脚本各自 die 里点名要的东西，不多不少。
  "${DOCKER[@]}" build -t "$TAG" -f - . >/dev/null <<EOF || die "构建镜像失败"
FROM $IMAGE_BASE
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y -qq \\
      build-essential clang lld cmake ninja-build git curl unzip zip file \\
      python3 python3-dev pkg-config ca-certificates \\
      zlib1g-dev libzstd-dev libbz2-dev libffi-dev libncurses-dev libnsl-dev \\
    && rm -rf /var/lib/apt/lists/*
EOF
  ok "构建好了"
fi
gl=$("${DOCKER[@]}" run --rm "$TAG" sh -c 'ldd --version | head -1') || die "镜像跑不起来"
note "容器里的 libc：$gl"

step "在容器里跑：$*"
note "REPO $REPO（只读）"
note "WORK $WORK（可写，路径原样）"
# **要把内层脚本认的环境变量带进去。** 头一版没带，于是
# `HERMES_TAG=… tools/build-in-container.sh tools/build-hermesc.sh --build`
# 在容器里用的是默认 tag —— 源码是 .0.16、包名写成 .0.17，**产物被贴错标签**。
# 想传别的就用 CONTAINER_ENV="VAR1 VAR2" 追加。
ENV_ARGS=()
for v in HERMES_TAG SIMPLEPERF LLVM_OUT OUT IMAGES SDK_TGZ NDK_TGZ \
         LLVM_BRANCH LLVM_PIN NDK_CLANG_VER NDK_CLANG_REV ANDROID_NDK_HOME PYTHON_OUT \
         ALLOW_QEMU ALLOW_TAG_MISMATCH ${CONTAINER_ENV:-}; do
  # 只传**确实设了**的，别把空值当成「用户要求设成空」
  [ -n "${!v+x}" ] && ENV_ARGS+=( -e "$v=${!v}" )
done
[ ${#ENV_ARGS[@]} -gt 0 ] && note "带进去的环境变量：$(printf '%s ' "${ENV_ARGS[@]}" | sed 's/-e //g')"

# **不加 --rm。** 容器退出就被删的话，日志跟着没 —— 而这里跑的是一小时起步的
# 编译，外面那个 shell 很容易先被杀掉（后台任务被回收、终端断线都会）。
# 容器归守护进程管，shell 死了它照编；只要容器还在，`docker logs` 就还能看。
# 实测踩过：LLVM 编到一半 shell 被回收，容器编完自删，日志全丢，只能靠产物反推。
# 跑完自己收拾，别攒垃圾。
CID_FILE=$(mktemp -u)
"${DOCKER[@]}" run --cidfile "$CID_FILE" \
  --user "$(id -u):$(id -g)" \
  -v "$REPO:$REPO:ro" \
  -v "$WORK:$WORK" \
  -e "WORK=$WORK" -e HOME=/tmp \
  "${ENV_ARGS[@]+"${ENV_ARGS[@]}"}" \
  -w "$REPO" \
  "$TAG" "$@"
rc=$?
if [ -f "$CID_FILE" ]; then
  # cidfile 是 docker 写的：走 sudo 时它归 root，普通用户删不掉（/tmp 有 sticky 位），
  # 每次跑完都打一行 Operation not permitted。用同一条路子删。
  cid=$(cat "$CID_FILE"); rm -f "$CID_FILE" 2>/dev/null || sudo -n rm -f "$CID_FILE" 2>/dev/null
  [ $rc = 0 ] && "${DOCKER[@]}" rm "$cid" >/dev/null 2>&1 \
    || note "容器留着了（$cid），日志：docker logs $cid；看完 docker rm $cid"
fi
[ $rc = 0 ] || die "容器里那条命令失败了（退出码 $rc）"
ok "跑完了"
note "**门槛降没降不由这里说了算** —— 用 tools/test-clean-machine.sh --docker 实测。"
