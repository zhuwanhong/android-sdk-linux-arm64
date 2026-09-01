#!/usr/bin/env bash
# 打两次包，比 sha256。**这是「可复现」这句话唯一的验收方式** —— 光看代码里
# 写了 --sort=name 不算数（我第一版就漏了 gzip 的 -n，代码看着对，包不一样）。
#
# 用法：
#   tools/check-reproducible.sh                        # SDK 包（默认）
#   tools/check-reproducible.sh --ndk /path/to/打过补丁的NDK   # NDK 包
#   tools/check-reproducible.sh --full       # 连不能发布的完整包也验
#
# 退出码：0 两次一致 / 1 不一致（会指出差在哪） / 2 没验成（缺前置条件）
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
die()  { printf '\n  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }
skip() { printf '\n  \033[33m?\033[0m %s\n' "$1" >&2; exit 2; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }

WHICH=sdk; MODE=--ours-only; NDK_SRC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ndk)  WHICH=ndk ;;
    --sdk)  WHICH=sdk ;;
    --full) MODE="" ;;
    -*) die "不认识的参数：$1" ;;
    *) NDK_SRC="$1" ;;
  esac
  shift
done
WORK="${WORK:-$REPO/work}"
[ -d "$WORK/out" ] || skip "$WORK/out 不在 —— 先把工具编出来再验打包可复现性。"

case "$WHICH" in
  sdk) SCRIPT_=tools/make-dist.sh ;;
  ndk) SCRIPT_=tools/make-ndk-dist.sh
       [ -n "$NDK_SRC" ] || skip "验 NDK 包要指一份**打过 tools/patch-ndk.sh 的** NDK：
    tools/check-reproducible.sh --ndk /path/to/ndk"
       [ -d "$NDK_SRC" ] || die "$NDK_SRC 不在"
       MODE="$MODE $NDK_SRC" ;;
esac

# **两次之间把 $OUTDIR 彻底删掉重建**。只重打 tar 是验不出东西的 ——
# 文件顺序那一项恰恰来自「目录是怎么建起来的」，不重建就永远看不到差异。
# **不要在 $(...) 里调它**：里头的 die 是 exit，在子 shell 里只退子 shell，
# 外层会拿着空值接着跑（tests/common.sh 的 pick 栽过这个，见 docs/zh/LESSONS.md）。
# 所以结果用全局变量 REPRO_TAR 带出来，不走 stdout。
REPRO_TAR=""
run_once() {   # $1 = 把包存到哪  $2 = 这次用的 OUTDIR
  local outdir="$2"
  rm -rf "$outdir"
  # shellcheck disable=SC2086
  # $3=unset 时，这一趟不给 SOURCE_DATE_EPOCH，走用户照文档复现的那条路
  local runner=env
  [ "${3:-}" = unset ] && runner="env -u SOURCE_DATE_EPOCH"
  # shellcheck disable=SC2086
  OUT="$outdir" $runner "$REPO/$SCRIPT_" $MODE >"$1.log" 2>&1 || {
    tail -20 "$1.log" >&2; die "$SCRIPT_ 跑失败了（完整输出见 $1.log）"
  }
  REPRO_TAR=$(grep -oE '/[^ ]*\.tar\.gz' "$1.log" | head -1)
  [ -n "$REPRO_TAR" ] && [ -f "$REPRO_TAR" ] || die "从输出里认不出打出来的包（看 $1.log）"
  cp -f "$REPRO_TAR" "$1"
  # 包已经拷出来了，目录立刻删掉：NDK 那个铺开有 3.5 GB，两次同时留着就是 7 GB，
  # GitHub runner 那 12 GB 装不下。要的是「两次各自从零建目录」，不是「两个目录同时在」。
  rm -rf "$outdir"
}

# **把时间基准钉住再打两次。** 不钉的话，两次之间只要有人提交一次代码，
# 默认基准（HEAD 的提交时间）就变了，PROVENANCE 里的时间跟着变，检查报红 ——
# 而那是输入变了，不是打包不确定。实测被自己坑过一次：两次打包中间我提交了
# 一个 commit，差异清单里只剩 PROVENANCE 的一行时间。
# 检查要问的是「输入相同时输出是否相同」，所以输入必须自己按住。
HEAD_EPOCH=$(git -C "$REPO" log -1 --format=%ct 2>/dev/null || true)
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
  SOURCE_DATE_EPOCH="${HEAD_EPOCH:-$(date -u +%s)}"
fi
export SOURCE_DATE_EPOCH
# **第二次故意不设 SOURCE_DATE_EPOCH**（只要它跟 HEAD 的提交时间相同）。
# 因为文档教用户的复现步骤是「checkout tag，直接跑打包脚本」—— 那条路上
# 变量是没设的，靠 HEAD 兜底。两条路必须出同样的字节，否则文档里的校验和
# 对不上。栽过一次：PROVENANCE 里写着「（取自 SOURCE_DATE_EPOCH）」，
# 换成靠 HEAD 推就变成「（取自 HEAD 的提交时间）」，同一个时间值、不同的包。
UNSET_2ND=0
[ -n "$HEAD_EPOCH" ] && [ "$SOURCE_DATE_EPOCH" = "$HEAD_EPOCH" ] && UNSET_2ND=1
note "时间基准钉在 SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH（$(date -u -d "@$SOURCE_DATE_EPOCH" '+%Y-%m-%d %H:%M:%S') UTC）"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
step "第一次打包"
# 目录名带上包类型：SDK 和 NDK 两个检查同时跑过一次，用的都是 $WORK/repro-a，
# 后开的那个把前一个正在打包的目录删了（tar 报 "File removed before we read it"）。
run_once "$T/a.tar.gz" "$WORK/repro-$WHICH-a"; ok "$(basename "$REPRO_TAR")  $(stat -c%s "$T/a.tar.gz") 字节"
step "第二次打包（目录整个重建，不是重打 tar）"
if [ "$UNSET_2ND" = 1 ]; then
  note "第二趟**不设 SOURCE_DATE_EPOCH**，走「checkout tag 直接打包」那条路"
  run_once "$T/b.tar.gz" "$WORK/repro-$WHICH-b" unset
else
  note "外面给的 SOURCE_DATE_EPOCH 跟 HEAD 的提交时间不同，第二趟也用它"
  run_once "$T/b.tar.gz" "$WORK/repro-$WHICH-b"
fi
ok "$(stat -c%s "$T/b.tar.gz") 字节"

step "比"
ha=$(sha256sum "$T/a.tar.gz" | cut -d' ' -f1)
hb=$(sha256sum "$T/b.tar.gz" | cut -d' ' -f1)
note "第一次 $ha"
note "第二次 $hb"
if [ "$ha" = "$hb" ]; then
  ok "两次打包逐字节一致 —— 可复现"
  rm -rf "$WORK/repro-$WHICH-a" "$WORK/repro-$WHICH-b"
  exit 0
fi

# 不一致的时候，光说「不一致」没用，得指出差在哪一层
step "不一致，往下挖"
mkdir -p "$T/xa" "$T/xb"
tar -xzf "$T/a.tar.gz" -C "$T/xa"; tar -xzf "$T/b.tar.gz" -C "$T/xb"
if diff -r "$T/xa" "$T/xb" > "$T/content.diff" 2>&1; then
  note "内容逐字节一样 —— 差别在 **tar/gzip 的元数据**里（mtime、顺序、uid/gid、gzip 头）"
  diff <(tar -tvzf "$T/a.tar.gz" | head -40) <(tar -tvzf "$T/b.tar.gz" | head -40) | head -20 | sed 's/^/      /'
else
  note "**内容本身**就不一样："
  head -20 "$T/content.diff" | sed 's/^/      /'
fi
die "两次打包结果不同，不能说这个包可复现。"
