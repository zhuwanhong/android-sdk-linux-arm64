#!/usr/bin/env bash
# 把自己编的那些产物摆成 sdkmanager 装出来的样子，打成一个能解压到 $ANDROID_HOME
# 的包。M4。
#
# ---------------------------------------------------------------------------
# 目录长什么样，**不猜，照着官方装出来的那份数**。
#
# 一份官方 SDK 里（版本会变，所以脚本是运行时读的，不是写死的清单）：
#
#   build-tools/<rev>/
#       aapt aapt2 aidl dexdump split-select zipalign     ELF，我们有
#       bcc_compat llvm-rs-cc                             ELF，RenderScript，废弃了
#       lld-bin/lld                                       ELF，要 build-llvm.sh 的产物
#       lib64/*.so                                        ELF，RenderScript 的支持库
#       apksigner d8 lld                                  bash 包装脚本
#       lib/apksigner.jar lib/d8.jar core-lambda-stubs.jar  Java，跟架构无关
#       *-linux-android-ld                                纯文本占位（见下）
#       renderscript/                                     头文件 + 各 ABI 的目标库
#       NOTICE.txt source.properties runtime.properties
#
#   platform-tools/
#       adb etc1tool fastboot hprof-conv make_f2fs        ELF
#       make_f2fs_casefold mke2fs sqlite3                 ELF
#       lib64/libc++.so                                   ELF，官方 adb/fastboot 用
#       mke2fs.conf                                       **少了 mke2fs 直接 abort**
#       NOTICE.txt source.properties
#
# ---------------------------------------------------------------------------
# 分类规则只有一条，但有个坑：
#
#   **一个 x86_64 的 .so 未必是「跑不了的砖」。**
#   renderscript/lib/ 底下按 ABI 分了 arm64-v8a / armeabi-v7a / x86 / x86_64
#   四个目录，里面的 x86 二进制是**给 x86 设备用的目标产物**，是要打进 APK 的，
#   照搬才对。真正必须换掉的是**跑在这台机器上的 host 二进制**。
#
#   所以判据是「位置」不是「架构」：路径里带 ABI 目录名的当目标产物原样拷，
#   其余位置上的 ELF 一律当 host 二进制处理 —— 我们有就换我们的，没有就**丢掉
#   并报出来**。绝不把 x86_64 的 host 二进制放进 ARM64 的包里：
#   README 第六节记过，PATH 里放一堆跑不了的二进制只有害处。
#
# ---------------------------------------------------------------------------
# 版本号怎么写：**不冒充官方包，也不自己编一个号。**
#
# **build-tools 和 platform-tools 两个包的答案不一样**，因为「这个包里的东西
# 主要是谁的」不一样：
#
#   build-tools    目录名和 Pkg.Revision 沿用**被借出 jar 的那个官方包**的版本。
#                  d8.jar / apksigner.jar 确实就是那一版，我们也不重编它们，
#                  AGP 按目录名判能力判的也是它们。
#   platform-tools 用**我们源码 tag 的版本**（AOSP platform-tools-<x>）。
#                  这个包里除了 mke2fs.conf 和 NOTICE.txt，几乎全是我们编的，
#                  照搬官方那份的版本号是在说一件不成立的事 —— 实测撞到了：
#                  一台机器上官方装的是 37.0.1，我们的 ELF 编自 35.0.2，
#                  照搬就会打出一个「37.0.1」但里面装着 35.0.2 二进制的包。
# 同时往包里写一份 PROVENANCE.txt，逐个文件写清楚哪些是自己编的、源码是哪个
# AOSP tag、哪些是从官方包原样拿的。**「哪些不是我们编的」必须写在包里，
# 不能只写在 README 里。**
#
# ---------------------------------------------------------------------------
# 这版不做的：
#   * NDK。它是另一个 sdkmanager 包，而且官方那份里 toolchains/llvm/prebuilt/
#     linux-x86_64 有 2 GB 的 x86 二进制，怎么裁是另一件事。
#   * platforms/android-XX。纯 Java + 数据，跟架构无关，用户手上那份直接能用。
#   * 能被 sdkmanager 识别的本地 repository XML（README 里列的加分项）。
#
# 用法：
#   tools/make-dist.sh --check     只报缺什么，不写文件
#   tools/make-dist.sh             摆好目录并打包
#   ANDROID_HOME=... OUT=... tools/make-dist.sh

set -uo pipefail

# 跟 tools/build-common.sh 里的一样。这个脚本不 source 它 —— 那套骨架是「取源码、
# 交叉编译、验产物」，跟打包一件事都不沾。
die()  { printf '\n  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1" >&2; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO/tools/repro.sh"   # 可复现打包：repro_init / repro_tar
repro_init
WORK="${WORK:-$REPO/work}"
# 我们编的产物都在这儿，文件名跟 SDK 里的一样
BUILT="$WORK/out"
# WORK 打错字是个常见错法，而且症状离病根很远：一路走到最后才在 tar 那步炸
# （实测 WORK=/nonexistent 时报的是 tar: Cannot open）。在这里就说清楚。
[ -d "$BUILT" ] || die "自己编的产物不在：$BUILT
    WORK 现在是 $WORK。先把工具编出来，或者 WORK=… 指对地方。"
# build-tools 里的 lld-bin/lld 是唯一一个不在 $BUILT 顶层的 host 二进制，
# 它由 tools/build-llvm.sh 顺带编出来（LLVM_ENABLE_PROJECTS 里有 lld）。
# **固定找 linux-aarch64 那份**，不是 $(uname -m)：这个包永远是给 ARM64 装的，
# 在 x86 上试打包时也不该把 x86 的 lld 塞进去。
LLD_OURS="$WORK/out/llvm/linux-aarch64/bin/lld"
# 源码 tag：所有 ELF 产物都是从这个 tag 的 AOSP 源码编的，见 tools/build-common.sh
AOSP_TAG=platform-tools-35.0.2

# 官方包里有、但**不打算做**的 host 二进制。跟「还没编出来」必须分开报 ——
# 混成一类，PROVENANCE.txt 里就会对着 RenderScript 那几个写「我们还没编出来」，
# 那是假话。格式：一行一个包内相对路径，`#` 之后是理由。
# （名字和理由别混在一行用空格分 —— tools/build-llvm.sh 那张放行名单踩过，
#  从理由里抠出过不存在的条目。下面同样有一条自检。）
KNOWN_WONTDO="
bcc_compat                # RenderScript，Google 从 Android 12 起废弃
llvm-rs-cc                # 同上
lib64/libLLVM_android.so  # RenderScript 的支持库
lib64/libbcc.so           # 同上
lib64/libbcinfo.so        # 同上
lib64/libclang_android.so # 同上
lib64/libc++.so           # 只有上面那几个动态链它；我们的产物都是 c++_static
lib64/libc++.so.1         # 同上
"

# 开头就把这个脚本自己是哪一版打出来 —— 「你跑的是哪一版」这个问题，
# 让它自己回答，别每次靠人去查。理由见 tools/build-common.sh 里同名函数。
_rev=$(git -C "$REPO" log -1 --format='%h %ad' --date=short -- "${BASH_SOURCE[0]}" 2>/dev/null)
printf '  \033[2m%s @ %s\033[0m\n' "$(basename "${BASH_SOURCE[0]}")" "${_rev:-（不在 git 里）}"

# **file(1) 是硬依赖，不是可选项。** 下面两道验收（「不许有 host 位置的 x86
# 二进制」「host 二进制真能跑」）都拿 `case "$(file -b …)" in *ELF*)` 当闸门；
# file 不在，命令替换是空串，每个文件都 continue，两道验收双双空转报绿。
# 实测过：往包里塞一个真的 x86-64 二进制，在没有 file 的 ubuntu:22.04 里跑
# 同一段，打印的是「host 位置上的 ELF 全是 ARM aarch64」。
# 这个仓库的规矩是「没验成」要跟「通过」分开，所以缺 file 直接死在这里。
command -v file >/dev/null || die "要 file(1)：sudo apt install -y file
    这个脚本的两道验收全靠它认架构，缺了会静默全绿 —— 宁可不出包。"

CHECK_ONLY=0; OURS_ONLY=0
case "${1:-}" in
  --check) CHECK_ONLY=1 ;;
  --ours-only) OURS_ONLY=1 ;;
  "") ;;
  *) die "不认识的参数：$1（--check / --ours-only）" ;;
esac

# **两种包分开放、分开命名**，不然很容易把不能发的那个当成能发的发出去。
# （放在参数解析**之后**：头一版放在前面，OURS_ONLY 还没赋值，set -u 当场拦下。）
if [ "$OURS_ONLY" = 1 ]; then
  OUTDIR="${OUT:-$WORK/dist-ours}"; TGZ_SUFFIX="-ours"
else
  OUTDIR="${OUT:-$WORK/dist}"; TGZ_SUFFIX=""
fi

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
[ -n "$SDK" ] && [ -d "$SDK" ] || die \
"找不到 SDK，设一下 ANDROID_HOME。

    这个脚本要从官方包里拿**跟架构无关**的那部分（d8.jar、apksigner.jar、
    包装脚本、NOTICE.txt、renderscript/ 等）。它们不是我们编的，也不需要编。"

# **输入必须是官方 SDK，不能是我们自己打出来的包。**
# 跟 make-ndk-dist.sh 那条守卫同一个理由，而且这里更容易撞上：把我们的包解进
# $ANDROID_HOME 之后（下游正是这么用的），这个脚本默认读的就是它自己的产物。
#
# 真跑过一遍：它会红，但报的是
#     ✗ 「不打算做」名单里有官方包里根本没有的条目： bcc_compat …
# —— 因为 RenderScript 那几个我们的包早丢掉了。**兜住了，但说的是名单错了**，
# 而真正错的是输入。两种原因共用一个出口，所以在这里先判一次。
if [ -f "$SDK/PROVENANCE.txt" ]; then
  die "$SDK **是我们自己打出来的包**（根目录有 PROVENANCE.txt），不是官方 SDK。

    这个脚本要从官方包里借跟架构无关的那部分（d8.jar、apksigner.jar、包装脚本、
    NOTICE.txt、renderscript/…）。拿我们自己的包当输入，借到的是「已经借过一轮
    并且丢过东西」的那份 —— 丢掉的再也回不来。

    指一份官方 SDK 过来：
      ANDROID_HOME=/path/to/官方/sdk tools/make-dist.sh
    没有的话用 cmdline-tools 装一份到**别的目录**（纯 Java，ARM 上跑得动）：
      sdkmanager --sdk_root=/path/to/官方/sdk "build-tools;36.0.0" "platform-tools"
    （装出来的是 x86_64 的二进制，没关系 —— 我们只借它的 jar 和脚本。）"
fi

# 挑一个 build-tools（版本号最大的那个）
SRC_BT=""
for d in "$SDK"/build-tools/*/; do SRC_BT="${d%/}"; done
[ -n "$SRC_BT" ] || die "$SDK/build-tools 底下什么都没有"
SRC_PT="$SDK/platform-tools"
[ -d "$SRC_PT" ] || die "$SRC_PT 不在"

BT_REV=$(basename "$SRC_BT")
PT_REV=$(sed -n 's/^Pkg.Revision=//p' "$SRC_PT/source.properties" 2>/dev/null)
PT_REV=${PT_REV:-unknown}
PT_OUT_REV=${AOSP_TAG#platform-tools-}   # 我们打出去的那份用这个

step "从哪儿拿"
note "官方 SDK        $SDK"
note "build-tools     $SRC_BT（$BT_REV）"
note "platform-tools  $SRC_PT（$PT_REV）"
note "自己编的产物    $BUILT"
if [ "$PT_REV" != "$PT_OUT_REV" ]; then
  warn "官方 platform-tools 是 $PT_REV，我们的 ELF 编自 $AOSP_TAG。
    打出去的那份标 Pkg.Revision=$PT_OUT_REV（按我们的源码算），不跟着 $PT_REV 走。
    从这个包里借的只有 mke2fs.conf 和 NOTICE.txt，PROVENANCE.txt 会写明。"
fi

# ---------------------------------------------------------------------------
# 一个文件该怎么处理
#   ours     $BUILT 里有同名产物 -> 用我们的
#   target   路径里带 ABI 目录名 -> 目标产物，原样拷（哪怕是 x86 的）
#   copy     不是 ELF -> 原样拷
#   drop     host 位置上的 ELF 而我们没有 -> 丢掉并报出来
# ---------------------------------------------------------------------------
is_abi_path() {  # $1=包内相对路径
  case "/$1/" in
    */arm64-v8a/*|*/armeabi-v7a/*|*/armeabi/*|*/x86/*|*/x86_64/*|*/riscv64/*|*/mips*/*) return 0 ;;
  esac
  return 1
}

# $1=官方包目录
assemble() {
  local src="$1" rel f typ
  ( cd "$src" && find . -type f -o -type l ) | sed 's|^\./||' | LC_ALL=C sort | while read -r rel; do
    f="$src/$rel"
    typ=$(file -b "$f" 2>/dev/null)
    if [ "$rel" = lld-bin/lld ] && [ -x "$LLD_OURS" ]; then
      echo "ours-lld|$rel"
    elif [ -x "$BUILT/$(basename "$rel")" ] && [ "$(dirname "$rel")" = "." ] \
       && case "$typ" in *ELF*) true ;; *) false ;; esac; then
      echo "ours|$rel"
    elif case "$typ" in *ELF*) true ;; *) false ;; esac; then
      if is_abi_path "$rel"; then echo "target|$rel"; else echo "drop|$rel|$(echo "$typ" | cut -d, -f2 | sed 's/^ //')"; fi
    else
      echo "copy|$rel"
    fi
  done
}

do_one() {  # $1=官方包目录  $2=输出目录  $3=包名（打印用）
  local src="$1" dst="$2" name="$3" line kind rel extra
  step "$name"
  [ "$CHECK_ONLY" = 1 ] || { rm -rf "$dst"; mkdir -p "$dst"; }
  local n_ours=0 n_copy=0 n_target=0 n_drop=0 n_wont=0 ours_list="" drop_list="" drop_all="" wont_list=""
  while IFS= read -r line; do
    kind=${line%%|*}; rest=${line#*|}
    rel=${rest%%|*}; extra=${rest#*|}; [ "$extra" = "$rel" ] && extra=""
    case "$kind" in
      ours)
        n_ours=$((n_ours+1)); ours_list="$ours_list $rel"
        [ "$CHECK_ONLY" = 1 ] || { mkdir -p "$dst/$(dirname "$rel")"; cp -a "$BUILT/$(basename "$rel")" "$dst/$rel"; } ;;
      ours-lld)
        n_ours=$((n_ours+1)); ours_list="$ours_list $rel"
        [ "$CHECK_ONLY" = 1 ] || { mkdir -p "$dst/$(dirname "$rel")"; cp -a "$LLD_OURS" "$dst/$rel"; } ;;
      target)
        n_target=$((n_target+1))
        [ "$CHECK_ONLY" = 1 ] || [ "$OURS_ONLY" = 1 ] || { mkdir -p "$dst/$(dirname "$rel")"; cp -a "$src/$rel" "$dst/$rel"; } ;;
      copy)
        n_copy=$((n_copy+1))
        [ "$CHECK_ONLY" = 1 ] || [ "$OURS_ONLY" = 1 ] || { mkdir -p "$dst/$(dirname "$rel")"; cp -a "$src/$rel" "$dst/$rel"; } ;;
      drop)
        if grep -qxF "$rel" <<<"$WONTDO"; then   # 不走管道，见 docs/LESSONS.md
          n_wont=$((n_wont+1)); wont_list="$wont_list $rel"
        else
          n_drop=$((n_drop+1)); drop_list="$drop_list $rel($extra)"
          drop_all="$drop_all $name/$rel($extra)"
        fi ;;
    esac
  done < <(assemble "$src")
  ok "自己编的 $n_ours 个：$(echo "$ours_list" | tr ' ' '\n' | grep -v '^$' | tr '\n' ' ')"
  if [ "$OURS_ONLY" = 1 ]; then
    ok "**没放进来** $((n_target + n_copy)) 个官方文件（jar / 包装脚本 / 各 ABI 的 .so / NOTICE 等）"
    note "它们受 Android SDK 的许可条款约束，我们不再分发 —— 装的时候由 tools/install.sh 从 Google 取"
  else
    ok "目标产物原样拷 $n_target 个（各 ABI 的 .so，不是 host 二进制）"
    ok "跟架构无关、原样拷 $n_copy 个（jar / 脚本 / 头文件 / NOTICE 等）"
  fi
  [ "$n_wont" -gt 0 ] && ok "$n_wont 个按「不打算做」丢掉（$(echo "$wont_list" | tr ' ' '\n' | grep -v '^$' | head -2 | tr '\n' ' ')…，理由见 PROVENANCE.txt）"
  if [ "$n_drop" -gt 0 ]; then
    warn "丢掉 $n_drop 个跑不了的 host 二进制 —— **这些是真缺口**："
    for x in $drop_list; do note "$x"; done
  fi
  DROP_TOTAL=$((DROP_TOTAL + n_drop))
  printf '%s' "$drop_all" >> "$WORK/.dist-drops"
}

WONTDO=$(printf '%s\n' "$KNOWN_WONTDO" | sed 's/#.*//' | tr -d ' \t' | grep -v '^$' | sort -u)
# 自检：名单里每一项都必须真的是官方包里的文件。多一个名字就等于对它静默放行。
ghost=""
for w in $WONTDO; do
  [ -e "$SRC_BT/$w" ] || [ -e "$SRC_PT/$w" ] || ghost="$ghost $w"
done
[ -z "$ghost" ] || die "「不打算做」名单里有官方包里根本没有的条目：$ghost
    名单写错了。多一个名字，就等于对那个名字静默放行。"

DROP_TOTAL=0
: > "$WORK/.dist-drops"
do_one "$SRC_BT" "$OUTDIR/build-tools/$BT_REV" "build-tools/$BT_REV"
do_one "$SRC_PT" "$OUTDIR/platform-tools"      "platform-tools"

if [ "$CHECK_ONLY" = 1 ]; then
  step "只是检查，没写文件"
  note "要真打包：tools/make-dist.sh"
  exit 0
fi

# ---------------------------------------------------------------------------
step "写 PROVENANCE.txt"
# 「哪些不是我们编的」必须跟着包走。
{
  echo "android-sdk-linux-arm64 —— 社区重建的 ARM64 Linux 版 Android SDK 组件"
  echo
  # **只写值，不写「值是怎么来的」**：同一个时间，设了 SOURCE_DATE_EPOCH 和
  # 靠 HEAD 推出来的，写进去的字不一样，包的 sha256 就不一样 —— 而文档让人
  # 「checkout tag 重打」正是后一种，等于文档里的复现步骤对不上已公布的校验和。
  # 差点就这么发出去了。$REPRO_SRC 只往 stdout 打，不进包。
  echo "生成时间（UTC）: $REPRO_STAMP   （SOURCE_DATE_EPOCH=$REPRO_EPOCH）"
  echo "生成机器架构  : $(uname -m)"
  echo
  echo "== 自己编的（源码 AOSP tag $AOSP_TAG，配方在本仓库 tools/ 和 cmake/ 下）=="
  for p in "$OUTDIR"/build-tools/*/ "$OUTDIR"/platform-tools/; do
    for f in "$p"*; do
      [ -f "$f" ] || continue
      b=$(basename "$f")
      [ -x "$BUILT/$b" ] || continue
      cmp -s "$f" "$BUILT/$b" && printf '  %s\n' "${f#"$OUTDIR"/}"
    done
  done
  for f in "$OUTDIR"/build-tools/*/lld-bin/lld; do
    [ -f "$f" ] && [ -x "$LLD_OURS" ] && cmp -s "$f" "$LLD_OURS" \
      && printf '  %s（tools/build-llvm.sh 顺带编的）\n' "${f#"$OUTDIR"/}"
  done
  echo
  echo "== 从官方包原样拿的（跟 host 架构无关，不需要重编）=="
  echo "  来源 build-tools   : 官方 build-tools $BT_REV"
  echo "  来源 platform-tools: 官方 platform-tools $PT_REV（只借了 mke2fs.conf 和 NOTICE.txt）"
  echo "  包括：d8.jar / apksigner.jar / core-lambda-stubs.jar 等 Java 产物，"
  echo "        apksigner / d8 / lld 等 bash 包装脚本，"
  echo "        renderscript/ 下各 ABI 的目标库（那些 x86 .so 是给 x86 设备用的，"
  echo "        不是 host 二进制），NOTICE.txt / source.properties 等。"
  echo
  echo "== 没放进来的 host 二进制：真缺口（官方包里有，我们还没编出来）=="
  d=$(tr ' ' '\n' < "$WORK/.dist-drops" | grep -v '^$' | sed 's/^/  /')
  [ -n "$d" ] && echo "$d" || echo "  （没有）"
  echo
  echo "== 没放进来的 host 二进制：不打算做 =="
  printf '%s\n' "$KNOWN_WONTDO" | grep -E '^[a-z0-9]' | sed 's/^/  /'
  echo
  echo "版本号："
  printf '  %-22s 沿用被借出 jar 的那个官方包的版本（d8.jar/apksigner.jar 就是那一版）\n' "build-tools/$BT_REV"
  printf '  %-22s 标 %s，按我们源码的 AOSP tag 算（这个包里几乎全是自己编的）\n' "platform-tools" "$PT_OUT_REV"
  echo "这不是 Google 发布的包，也不冒充。"
} > "$OUTDIR/PROVENANCE.txt"
ok "$OUTDIR/PROVENANCE.txt"

# source.properties 标上不是官方包
for p in "$OUTDIR/build-tools/$BT_REV" "$OUTDIR/platform-tools"; do
  [ -f "$p/source.properties" ] || continue
  # **文件不在就别打勾。** --ours-only 的包里没有 source.properties（它是官方的），
  # 头一版照样打印「两个都标好了」—— 假绿。
  if [ ! -f "$p/source.properties" ]; then
    [ "$OURS_ONLY" = 1 ] || die "$p/source.properties 不在 —— 官方包里该有的"
    continue
  fi
  sed -i 's/^Pkg.UserSrc=false/Pkg.UserSrc=true/' "$p/source.properties"
  case "$p" in
    */platform-tools) sed -i "s/^Pkg.Revision=.*/Pkg.Revision=$PT_OUT_REV/" "$p/source.properties" ;;
  esac
  grep -q '^Pkg.Desc=' "$p/source.properties" || \
    echo "Pkg.Desc=rebuilt for linux-aarch64 by android-sdk-linux-arm64 (AOSP $AOSP_TAG); see PROVENANCE.txt" \
      >> "$p/source.properties"
done
if [ "$OURS_ONLY" = 1 ]; then
  note "source.properties 不在这个包里（它是官方的）—— install.sh 取回官方包之后由它来标"
else
  ok "两个 source.properties 都标了 Pkg.UserSrc=true + Pkg.Desc"
fi

# ---------------------------------------------------------------------------
step "验：包里不许有跑不了的 host 二进制"
# 这是这个包唯一的硬指标。判据同上：ABI 目录下的是目标产物，放过；
# 其余位置的 ELF 必须是 ARM aarch64。
bad=0; n_elf=0
while IFS= read -r f; do
  rel=${f#"$OUTDIR"/}
  t=$(file -b "$f")
  case "$t" in *ELF*) ;; *) continue ;; esac
  is_abi_path "$rel" && continue
  n_elf=$((n_elf+1))
  case "$t" in
    *"ARM aarch64"*) ;;
    *) warn "$rel 是 $(echo "$t" | cut -d, -f2)"; bad=$((bad+1)) ;;
  esac
done < <(find "$OUTDIR" -type f)
[ "$bad" = 0 ] || die "$bad 个 host 位置上的二进制不是 aarch64。这包不能发。"
# **一个都没查到 ≠ 全都合格。** 上面每条判断都以「file 认出是 ELF」为前提，
# 那么「零个 ELF」意味着这道检查根本没生效（file 坏了、包是空的、OUTDIR 指错了），
# 不能拿它当通过。
[ "$n_elf" -gt 0 ] || die "host 位置上一个 ELF 都没看到 —— 这不叫通过，是没验成。
    包在 $OUTDIR，$(find "$OUTDIR" -type f | wc -l) 个文件。先确认 file(1) 认得出它们。"
ok "host 位置上的 $n_elf 个 ELF 全是 ARM aarch64"

step "验：包里的 host 二进制真的能跑"
# 第五节第 2 条：「文件存在」不是验收。上一步只问了 file 说它是什么架构 ——
# 那正是 aapt2 那次栽的地方（文件在、有可执行位、exec 是 126）。
# 这一步真跑一遍，判据跟 tests/common.sh 的 runs() 一样：退出码 < 126。
if [ "$(uname -m)" != aarch64 ] && [ "$(uname -m)" != arm64 ]; then
  note "这台是 $(uname -m)，包里是 aarch64 的二进制，跑不了 —— 跳过。"
  note "**这一条没验过**。到 ARM64 机器上重跑 tools/make-dist.sh 才算数（第五节第 1 条）。"
else
  runs_pkg() {  # 退出码 < 126 就算能跑；124 是 timeout，单独算失败
    local rc
    timeout 10 "$1" --version </dev/null >/dev/null 2>&1; rc=$?
    [ "$rc" = 124 ] && return 2
    [ "$rc" -lt 126 ] && return 0
    timeout 10 "$1" </dev/null >/dev/null 2>&1; rc=$?
    [ "$rc" = 124 ] && return 2
    [ "$rc" -lt 126 ]
  }
  n_ran=0; cant=""; hung=""
  while IFS= read -r f; do
    rel=${f#"$OUTDIR"/}
    case "$(file -b "$f")" in *ELF*) ;; *) continue ;; esac
    is_abi_path "$rel" && continue      # 目标产物，本来就不该在这台上跑
    runs_pkg "$f"; case $? in
      0) n_ran=$((n_ran+1)) ;;
      2) hung="$hung $rel" ;;
      *) cant="$cant $rel" ;;
    esac
  done < <(find "$OUTDIR" -type f)
  [ -z "$cant" ] || die "这几个在包里、是 aarch64、但跑不起来（退出码 >= 126）：$cant
    「文件存在」和「能用」是两件事。"
  [ -z "$hung" ] || die "这几个跑起来卡住了（10 秒没退）：$hung
    多半是它在等标准输入 —— 换个参数试，别放过。"
  # 同上：跑过 0 个不是「都能起来」。WORK 指错时实测打印过
  # 「✓ 0 个 host 二进制真跑过一遍，都能起来」—— 那是假绿。
  [ "$n_ran" -gt 0 ] || die "一个 host 二进制都没跑到 —— 这不叫通过，是没验成。"
  ok "$n_ran 个 host 二进制真跑过一遍，都能起来"
fi

if [ "$OURS_ONLY" = 1 ]; then
  step "验：mke2fs.conf / NOTICE.txt（--ours-only 下不适用）"
  note "这两样是从官方包借的，--ours-only 的包里本来就没有 —— 由 install.sh 取官方包时带进来"
else
step "验：mke2fs.conf 在"
# README 第六节记过：缺了它 mke2fs 直接 abort，而它不是二进制，最容易漏。
[ -f "$OUTDIR/platform-tools/mke2fs.conf" ] || die "platform-tools/mke2fs.conf 没了 —— 缺了它 mke2fs 直接 abort"
ok "platform-tools/mke2fs.conf"

step "验：NOTICE.txt 都在"
for p in "$OUTDIR/build-tools/$BT_REV" "$OUTDIR/platform-tools"; do
  [ -s "$p/NOTICE.txt" ] || die "$p/NOTICE.txt 没了或是空的 —— 许可证声明必须跟着包走"
done
ok "两个 NOTICE.txt"
fi

# ---------------------------------------------------------------------------
step "打包"
TAR="$WORK/android-sdk-linux-arm64-$BT_REV$TGZ_SUFFIX.tar.gz"
rm -f "$TAR"
repro_tar "$OUTDIR" "$TAR" || die "打包失败"
ok "$TAR（$(du -h "$TAR" | cut -f1)）"

if [ "$OURS_ONLY" != 1 ]; then
  step "⚠️ 这个包**不能发布**"
  note "里面有 130 多个从官方 SDK 原样拷来的文件（d8.jar / apksigner.jar /"
  note "包装脚本 / renderscript 资源…），受 **Android SDK 许可条款**约束，**不允许再分发**。"
  note "我们自己从 AOSP 源码编的那些是 Apache-2.0，没问题 —— 问题只在借来的那批。"
  note ""
  note "本地自己用没关系。**要发布用**：  tools/make-dist.sh --ours-only"
  note "那个包只含我们编的二进制；缺的部分由 tools/install.sh 装的时候从 Google 取。"
fi

step "好了"
note "目录：$OUTDIR"
note "装法：tar -C \$ANDROID_HOME -xzf $TAR"
note ""
if [ "$DROP_TOTAL" -gt 0 ]; then
  note "**这个包不完整**：$DROP_TOTAL 个 host 二进制没放进来，清单在 PROVENANCE.txt。"
  note "装上之后它们就是缺的，不是坏的 —— 比放一个跑不了的 x86 二进制强。"
fi
if [ "$OURS_ONLY" = 1 ]; then
  note "**这个包是给发布用的**：只含我们从 AOSP 源码编出来的二进制（Apache-2.0）。"
  note "官方那部分（d8.jar / apksigner / 包装脚本 / renderscript 资源…）**故意不放**，"
  note "由 tools/install.sh 装的时候从 Google 取 —— 用户在那一步接受 Google 的条款。"
  note "所以它**不能单独解压就用**，要走：tools/install.sh --sdk-root … --sdk-tgz 这个包"
else
  note "没包含：NDK、platforms/android-XX、sdkmanager 用的 repository XML。见脚本开头。"
fi
