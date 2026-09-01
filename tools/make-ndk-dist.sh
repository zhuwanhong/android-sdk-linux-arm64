#!/usr/bin/env bash
# 把一份**已经改造好的 NDK** 打成能分发的 ARM64 包。
#
# 起因：`tools/make-dist.sh` 出的包解压完，**纯 Java 的 app 立刻能编**
# （aapt2 + d8 + apksigner + zipalign + android.jar，一条都不碰 NDK）。
# 但要编带原生库的 app，用户还得自己走一遍：装官方 NDK -> patch-ndk.sh ->
# build-llvm.sh（一小时）-> build-python.sh。**那是这个包目前最大的门槛。**
#
# ---------------------------------------------------------------------------
# 判据跟 make-dist.sh 一样：**按位置，不按架构**
#
# 但 NDK 的位置判据跟 SDK **不是同一条**，这里栽过一次，记下来：
#
#   SDK 里目标产物在 `renderscript/lib/<abi>/` —— 目录名是 ABI（arm64-v8a…）。
#   NDK 里目标产物在 `sysroot/usr/lib/<triple>/` —— 目录名是**三元组**
#   （x86_64-linux-android、i686-linux-android、arm-linux-androideabi…）。
#   直接把 make-dist.sh 的 is_abi_path() 搬过来，`sysroot/` 底下 1000 多个
#   x86/ARM 的目标库会被当成「host 位置上的异架构文件」，包直接打不出来。
#
# 所以这里反过来写：**列出 host 二进制会出现的位置**，其余一律当目标产物。
# 数出来只有七处（见 is_host_pos）。这条名单在**官方原版 x86_64 NDK 上校准过**：
#
#   host 位置 ELF 133 个，133 个全是 x86-64   —— 一个目标产物都没被误判进来
#   目标位置 ELF 1753 个
#   有 Linux INTERP 却不在 host 位置的：0 个   —— 一个 host 二进制都没漏在外面
#
# 「放行名单比检查清单危险」——所以这条名单自己也要被查：见「验二」，
# 它不靠位置，靠 ELF 里的动态链接器（INTERP），把整棵树重扫一遍。
#
# 四处 host 目录的处置：
#   toolchains  换成自己编的 linux-aarch64（tools/build-llvm.sh 的产物）
#   prebuilt    **丢掉**。ndk-build 找不到会退回系统 make，实测能用
#   shader-tools **丢掉**。glslc / spirv-* 没有 aarch64 版，编 Vulkan shader 才用得上
#   simpleperf/bin/linux 官方那份（x86_64）丢掉，换成自己编的 aarch64 那份
#                        （没编出来就是不含，会明说）；android/ 那半原样留着
#
# ---------------------------------------------------------------------------
# 用法：
#   tools/make-ndk-dist.sh [NDK 路径]
#
# 前提（脚本会逐条查，缺哪条报哪条）：
#   1. 那份 NDK 打过 tools/patch-ndk.sh 的补丁
#   2. toolchains/llvm/prebuilt/linux-aarch64 是**自己编的**，不是薄壳
#   3. 那份工具链里的 python3 是自足的（tools/build-python.sh 编的）

set -uo pipefail

die()  { printf '\n  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1" >&2; }

# file(1) 是硬依赖：下面用 `case "$(file -b …)" in *ELF*)` 当闸门的地方，
# file 一缺就是空串 -> 全部 continue -> 检查空转报绿。实测过（见 docs/zh/LESSONS.md）。
command -v file >/dev/null || die "要 file(1)：sudo apt install -y file
    这个脚本靠它认二进制架构，缺了检查会静默空转。"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO/tools/repro.sh"   # 可复现打包：repro_init / repro_tar
repro_init
WORK="${WORK:-$REPO/work}"
OUTROOT="${OUT:-$WORK/dist-ndk}"

_rev=$(git -C "$REPO" log -1 --format='%h %ad' --date=short -- "${BASH_SOURCE[0]}" 2>/dev/null)
printf '  \033[2m%s @ %s\033[0m\n' "$(basename "${BASH_SOURCE[0]}")" "${_rev:-（不在 git 里）}"

OURS_ONLY=0
if [ "${1:-}" = "--ours-only" ]; then OURS_ONLY=1; shift; fi
NDK="${1:-${ANDROID_NDK_HOME:-${ANDROID_NDK:-}}}"
if [ -z "$NDK" ]; then
  for c in "$WORK"/android-ndk-* "${ANDROID_HOME:-}"/ndk/*; do
    [ -d "$c/toolchains/llvm/prebuilt" ] && { NDK="$c"; break; }
  done
fi
[ -n "$NDK" ] && [ -f "$NDK/source.properties" ] || die "找不到 NDK。传路径：tools/make-ndk-dist.sh /path/to/ndk"
NDK=$(cd "$NDK" && pwd)

# **输入必须是官方原版 NDK，不能是我们自己打出来的包。**
# 这条守卫是踩出来的：把官方那份从 $ANDROID_HOME 挪走、换成我们的包之后，
# 上面那段自动查找会挑中**我们自己的产物**，于是「拿产物当输入」。
# 真跑过一遍：它会一路绿到验五才挂，报的是「一个被丢掉的目录都没记下来，
# 这条检查等于没做」—— 兜住了，但那句话说的是名单为空，
# **同一个出口下还可能是「官方 NDK 改了目录结构」**，两种原因分不开。
# 所以在这里先判一次，把话说清楚。
if [ -f "$NDK/PROVENANCE.txt" ] || grep -q '^Pkg\.Provenance = ' "$NDK/source.properties" 2>/dev/null; then
  die "$NDK **是这个脚本自己打出来的包**（有 PROVENANCE.txt / Pkg.Provenance），不是官方原版。

    拿产物当输入编不出正确的包 —— prebuilt/ 已经丢过、软链已经建过、
    出处行会写第二遍，而且几道检查会因为「没东西可丢」而变成空转。

    传官方那份的路径过来：
      tools/make-ndk-dist.sh /path/to/官方/android-ndk-r27b
    没有的话去 developer.android.com/ndk/downloads 下 linux 版（x86_64 那个包，
    我们只用它的目标产物和构建系统，host 工具链由 tools/build-llvm.sh 换掉）。"
fi

VER=$(sed -n 's/^Pkg.Revision *= *//p' "$NDK/source.properties" | tr -d ' \r')
[ -n "$VER" ] || die "读不出 $NDK/source.properties 里的 Pkg.Revision"
TC="$NDK/toolchains/llvm/prebuilt/linux-aarch64"

step "从哪儿来"
note "NDK  $NDK"
note "版本 $VER"

# ---------------------------------------------------------------------------
# NDK 里 host 二进制**只**出现在这七处。其余一律目标产物，原样拷。
# 官方 x86_64 NDK 上校准过，见文件头。
is_host_pos() {   # $1 = 包内相对路径；真 = 这个位置上的东西必须能在 aarch64 上跑
  local p=$1
  case "$p" in
    toolchains/llvm/prebuilt/*)
      p=${p#toolchains/llvm/prebuilt/}; p=${p#*/}    # 去掉 <host tag>/
      # 顺序有意义：python3/ 底下也有 lib/，先判它，别掉进下面的 lib/ 分支
      case "$p" in
        bin/*|libexec/*|python3/*) return 0 ;;
        lib/*/*) return 1 ;;   # lib/clang/、lib/<triple>/ —— 交叉目标的运行时库
        lib/*)   return 0 ;;   # lib/ 这一层 —— libc++.so.1、LLVMPolly.so 之类 host 的
      esac
      return 1 ;;              # sysroot/ musl/ share/ include/ —— 全是目标或纯文本
    prebuilt/*/*|shader-tools/*/*|simpleperf/bin/linux/*/*) return 0 ;;
  esac
  return 1                     # sources/ build/ meta/ simpleperf/bin/android/ …
}

# 扫一棵树，一趟把两件事都问了 —— file(1) 每个文件只调一次。
# （分成两趟写过，2 GB 的树每趟 55 秒，白等一分钟。）
#   按位置  ：host 位置上的 ELF 必须是 aarch64      -> n_host / n_target / scan_bad
#   按 INTERP：要 Linux 动态链接器的都是 host 二进制 -> n_interp / scan_stray
# 两条判据互相独立、互为兜底，报的时候还是分开报（验一、验二）。
scan_tree() {   # $1 = 树根
  local root=$1 f rel t
  n_host=0; n_target=0; n_interp=0; scan_bad=""; scan_stray=""
  while IFS= read -r f; do
    rel=${f#"$root"/}
    t=$(file -b "$f" 2>/dev/null); case "$t" in *ELF*) ;; *) continue ;; esac
    case "$t" in *"interpreter /lib"*) n_interp=$((n_interp+1)) ;; esac
    if is_host_pos "$rel"; then
      n_host=$((n_host+1))
      case "$t" in *"ARM aarch64"*) ;; *) scan_bad="$scan_bad $rel[$(printf '%s' "$t" | cut -d, -f2 | tr -d ' ')]" ;; esac
    else
      n_target=$((n_target+1))
      # 位置说它是目标产物，可它要 Linux 的动态链接器 —— 那是名单漏了一处
      case "$t" in *"interpreter /lib"*) scan_stray="$scan_stray $rel" ;; esac
    fi
  done < <(find "$root" -type f)
}

# ---------------------------------------------------------------------------
step "先自检：把坏文件塞进去，看抓不抓得住"
# 第五节第 5 条：每一步验证都从一个**必须失败**的测试开始。
# 造假树不需要真的 x86_64 二进制 —— 64 字节的 ELF 头就够 file(1) 报出架构，
# 所以这条自检在任何机器上都跑得起来（在 aarch64 上更要跑）。
RED=$(mktemp -d) || die "mktemp 失败"
_mkelf() { mkdir -p "$(dirname "$1")"
           printf '\177ELF\002\001\001\000\000\000\000\000\000\000\000\000\002\000%b\001\000\000\000' "$2" > "$1"
           dd if=/dev/zero bs=1 count=40 >> "$1" 2>/dev/null; }
_mkelf "$RED/toolchains/llvm/prebuilt/linux-aarch64/bin/clang"   '\267\000'  # 好的
_mkelf "$RED/toolchains/llvm/prebuilt/linux-aarch64/bin/BAD-x86" '\076\000'  # host 位置放 x86 —— 验一必须抓住
_mkelf "$RED/toolchains/llvm/prebuilt/linux-aarch64/sysroot/usr/lib/x86_64-linux-android/34/libc.so" '\076\000'  # 目标产物 —— 必须放行
_mkelf "$RED/simpleperf/bin/android/x86_64/simpleperf" '\076\000'            # 目标产物 —— 必须放行
# 验二的诱饵：一个**真的**、动态链接的 host 二进制，塞在目标产物的位置上。
# 这个合不出来（得有 PT_INTERP），从本机拿现成的。
BAIT=""; want_target=2
for c in /bin/sh /bin/cat /usr/bin/file /bin/ls /bin/true; do
  [ -f "$c" ] || continue
  case "$(file -b "$c" 2>/dev/null)" in *"interpreter /lib"*) BAIT=$c; break ;; esac
done
if [ -n "$BAIT" ]; then
  mkdir -p "$RED/sources/third_party" && cp "$BAIT" "$RED/sources/third_party/bait" && want_target=3
fi
scan_tree "$RED"
case "$scan_bad" in
  *BAD-x86*) ;;
  *) rm -rf "$RED"; die "自检没通过：host 位置上的 x86 文件**没被抓住**。
    is_host_pos() 判错了，后面的检查全是摆设。" ;;
esac
case "$scan_bad" in
  *libc.so*|*simpleperf*) rm -rf "$RED"; die "自检没通过：目标产物被当成 host 文件误报了（$scan_bad）。
    这条一旦误报，谁都打不出包 —— 判据写错了，改 is_host_pos()。" ;;
esac
[ "$n_host" = 2 ] && [ "$n_target" = "$want_target" ] \
  || { rm -rf "$RED"; die "自检没通过：数错了（host=$n_host 目标=$n_target，该是 2/$want_target）"; }
ok "验一的自检过了：坏文件抓住，目标产物放行，计数对（host 2 / 目标 $want_target）"
if [ -n "$BAIT" ]; then
  case "$scan_stray" in
    *bait*) ok "验二的自检过了：藏在 sources/ 里的 host 二进制也抓住了" ;;
    *) rm -rf "$RED"; die "自检没通过：藏在 sources/ 里的 host 二进制**没被抓住** —— 验二是摆设。" ;;
  esac
else
  warn "这台上找不到动态链接的 host 二进制当诱饵，**验二没自检**。"
  note "不是「自检过了」，是「没做」。"
fi
rm -rf "$RED"

# ---------------------------------------------------------------------------
step "查前提"
[ -x "$TC/bin/clang" ] || die "$TC/bin/clang 不在。
    先把自己编的工具链装进去：
        tools/build-llvm.sh --build
        rm -rf $TC && cp -a \$WORK/out/llvm/linux-aarch64 $TC"
[ -e "$TC/.shim-generated" ] && die "$TC 是**薄壳**（tools/make-shim-toolchain.sh 搭的）。
    薄壳里的 clang 是转发到系统 clang 的包装脚本、sysroot 是软链 —— 打不了包。
    换成自己编的那份，见上一条。"
# sysroot 和 lib/clang 必须是真目录不是软链，否则打出去的包是空壳
for d in sysroot lib/clang; do
  [ -L "$TC/$d" ] && die "$TC/$d 是软链，不是真目录 —— 打出去的包解压完会缺东西。
    tools/build-llvm.sh --build 出来的那份是拷贝，用它。"
  [ -d "$TC/$d" ] || die "$TC/$d 不在"
done
ok "工具链是自己编的（sysroot 和 lib/clang 都是实打实的目录）"

# python3 自足：判据跟 build-llvm.sh 第 6.5 步一样，是 sys.prefix 不是「文件在不在」
P3="$TC/python3/bin/python3"
PYVER=""
if [ -x "$P3" ] && pfx=$("$P3" -c 'import sys;print(sys.prefix)' 2>/dev/null) \
   && [ "$pfx" = "$TC/python3" ]; then
  PYVER=$("$P3" -c 'import sys;print(sys.version.split()[0])')
  ok "python3 自足（$PYVER）"
elif [ "$(uname -m)" != aarch64 ] && [ "$(uname -m)" != arm64 ]; then
  die "这台是 $(uname -m)，跑不了工具链里的 aarch64 python3，**所以查不了它自不自足**。
    这一条不能跳过 —— 「测不了」和「测过了」不是一回事。
    到 ARM64 机器上打包。"
else
  die "$TC/python3 不自足（sys.prefix = ${pfx:-读不出来}）。
    打出去的包在别人机器上会**静默降级**成裸 python。补上：
        tools/build-python.sh --fetch && tools/build-python.sh --build
        tools/build-llvm.sh --build   # 它会把 python3 拷进工具链
    然后重新装进 NDK。"
fi

"$REPO/tools/patch-ndk.sh" --check "$NDK" >/dev/null 2>&1 \
  || die "NDK 的补丁没打全。跑：tools/patch-ndk.sh $NDK
    不打补丁的 NDK 在 aarch64 上算出来的 host tag 还是 linux-x86_64。"
ok "补丁都打上了"

# 先看盘够不够 —— 整棵拷再删，峰值是「原树 + 拷贝」，中途没空间比一开始就说难看
need=$(du -sk "$NDK" | cut -f1)
have=$(df -Pk "$(dirname "$OUTROOT")" 2>/dev/null | awk 'NR==2{print $4}')
if [ -n "$have" ] && [ "$have" -lt "$need" ]; then
  die "盘不够：拷这份 NDK 要 $((need/1024)) MB，$(dirname "$OUTROOT") 只剩 $((have/1024)) MB。"
fi

# ---------------------------------------------------------------------------
OUTDIR="$OUTROOT/ndk/$VER"
step "摆目录"
rm -rf "$OUTROOT"; mkdir -p "$OUTDIR"
# 先整棵拷过来，再把别的 host tag 的目录删掉 —— 比逐个挑白名单稳：
# NDK 里跟架构无关的东西太多（sources/ build/ meta/ python-packages/ …），
# 漏掉一个就是个装完才发现的坑。
cp -a "$NDK/." "$OUTDIR/" || die "拷 NDK 失败"

dropped=""; dropped_paths=""
drop_dir() {  # $1=包内相对路径
  [ -e "$OUTDIR/$1" ] || return 0
  dropped="$dropped $1($(du -sh "$OUTDIR/$1" | cut -f1))"
  dropped_paths="$dropped_paths $1"
  rm -rf "$OUTDIR/$1"
}
for d in "$OUTDIR"/toolchains/llvm/prebuilt/*/; do
  t=$(basename "${d%/}"); [ "$t" = linux-aarch64 ] || drop_dir "toolchains/llvm/prebuilt/$t"
done
# prebuilt/ 不能整个丢 —— 这个目录是**混的**，同一个 bin/ 里既有 x86 ELF
# （make / yasm / vsyasm / ytasm）又有跟架构无关的东西
# （ndk-gdb / ndk-stack / ndk-which 三个 bash 脚本 + 两个 .pyz）。
# 而 NDK 顶层的 ndk-stack / ndk-gdb / ndk-which / ndk-lldb 都**写死**转发到
# prebuilt/linux-x86_64/bin/ —— 把整个目录丢掉，这四个入口就全坏了。
# 实测（原版 r27b，x86_64 上）：
#     prebuilt 在  ->  ./ndk-stack --help 退出码 0
#     prebuilt 丢  ->  退出码 127，not found
# 这四个入口在 aarch64 上**本来是能用的**（脚本 + pyz，跟架构无关），
# 丢掉是我们把它弄坏的，不是本来就没有。所以：非 ELF 的搬进 linux-aarch64/，
# ELF 的连同 include/ lib/ share/（都是 yasm 的配套）一起丢。
# ndk-gdb 那套带不带，看工具链里有没有 lldb —— **判据不写死**，将来编了
# lldb 这里自动跟着变。为什么它跟 ndk-stack 不一样：
#   ndkstack.pyz  ndk_host_tag = ndk_bin.parent.name  —— 从自己所在目录推导，
#                 搬进 linux-aarch64/bin/ 就自动对了；它要的 llvm-symbolizer 我们编了。
#   ndkgdb.pyz    get_llvm_host_name() 直接 `return "linux-x86_64"`，写死；
#                 而且它要 toolchains/llvm/prebuilt/<tag>/ 底下的 liblldb.so。
# 没编 lldb 还把 ndk-gdb 放进去，就是「文件在、一跑就错」—— 比没有更糟。
# 判的是「**包里**会不会有 lldb」，不是「输入树里能不能跑 lldb」——这两件事不一样，
# 而且第一次写成了后者：`[ -x "$TC/bin/lldb" ]`。
# 输入树多半被 link-system-tools.sh 处理过，那里的 lldb 是一条 `-> /usr/bin/lldb`
# 的软链：-x 为真 -> 判「有 lldb」-> ndk-gdb / ndkgdb.pyz 放进包；可**同一个脚本
# 随后又因为「指向包外、包必须自足」把那条软链剪掉**。于是打出来的包里
# ndk-gdb 在、lldb 不在 —— 正是下面注释里说要避免的「文件在、一跑就错」。
# 2026-08-29 实测撞上：同一棵树删掉那条软链前后，包差了 ndk-gdb + ndkgdb.pyz 两个。
# 所以只认**留得下来的** lldb：真文件，或指向包内的软链。
HAS_LLDB=0
if [ -f "$TC/bin/lldb" ] && [ -x "$TC/bin/lldb" ]; then
  # -f 跟到软链尽头，所以还要确认它没指到树外面去
  tgt=$(readlink -f "$TC/bin/lldb" 2>/dev/null)
  case "$tgt" in "$NDK"/*) HAS_LLDB=1 ;; esac
fi

pb_moved=0; pb_skipped=""
if [ -d "$OUTDIR/prebuilt" ]; then
  for d in "$OUTDIR"/prebuilt/*/; do
    t=$(basename "${d%/}"); [ "$t" = linux-aarch64 ] && continue
    for f in "$d"bin/*; do
      [ -f "$f" ] || continue
      case "$(file -b "$f" 2>/dev/null)" in *ELF*) continue ;; esac
      b=$(basename "$f")
      if [ "$HAS_LLDB" = 0 ]; then
        case "$b" in ndk-gdb|ndkgdb.pyz) pb_skipped="$pb_skipped $b"; continue ;; esac
      fi
      mkdir -p "$OUTDIR/prebuilt/linux-aarch64/bin"
      [ -e "$OUTDIR/prebuilt/linux-aarch64/bin/$b" ] && continue
      cp -a "$f" "$OUTDIR/prebuilt/linux-aarch64/bin/$b" || die "搬不动 $b"
      # 文本文件里写死的 host tag 跟着改。ndk-which 的注释就写着
      # 「This tool is installed in prebuilt/linux-x86_64/bin/」—— 搬完不改，
      # 注释本身就是错的（验五也会报它）。
      case "$(file -b "$OUTDIR/prebuilt/linux-aarch64/bin/$b" 2>/dev/null)" in
        *text*) sed -i 's|prebuilt/linux-x86_64|prebuilt/linux-aarch64|g' \
                  "$OUTDIR/prebuilt/linux-aarch64/bin/$b" ;;
      esac
      pb_moved=$((pb_moved+1))
    done
    drop_dir "prebuilt/$t"
  done
fi
for d in "$OUTDIR"/shader-tools/*/; do drop_dir "shader-tools/$(basename "${d%/}")"; done

# ---------------------------------------------------------------------------
# simpleperf 的 host 那半。
#
# 官方只发 bin/linux/x86_64/，我们自己编（tools/build-simpleperf.sh）。
# **摆到 bin/linux/aarch64/**，下面那个循环就会把 x86_64 那份丢掉、留下这份；
# 再往下补一条 x86_64 -> aarch64 的软链，因为 simpleperf 自己的 python 脚本
# 把 host 目录**写死成 x86_64**（simpleperf_utils.py 里
# `os.path.join(dirname, 'x86_64' if sys.maxsize > 2**32 else 'x86')`，
# 跟机器架构无关）—— 跟 prebuilt/linux-x86_64 那条软链是同一个道理。
#
# 没编就明说没编，不静默跳过。
SP_HOST="${SIMPLEPERF:-$WORK/out/simpleperf}"
if [ -x "$SP_HOST" ]; then
  mkdir -p "$OUTDIR/simpleperf/bin/linux/aarch64"
  cp "$SP_HOST" "$OUTDIR/simpleperf/bin/linux/aarch64/simpleperf" || die "拷 simpleperf 失败"
  chmod +x "$OUTDIR/simpleperf/bin/linux/aarch64/simpleperf"
  ok "装上自己编的 simpleperf（$(stat -c%s "$SP_HOST") 字节）"
else
  warn "没找到 $SP_HOST —— **这个包里不含 simpleperf 的 host 那半**。"
  note "要它就先跑 tools/build-simpleperf.sh，或者 SIMPLEPERF=<路径> 指过来。"
fi

for d in "$OUTDIR"/simpleperf/bin/linux/*/; do
  a=$(basename "${d%/}"); [ "$a" = aarch64 ] || drop_dir "simpleperf/bin/linux/$a"
done
# python 脚本写死 x86_64，给它一条软链（理由见上面那段）。
# 建在丢弃循环**之后** —— 建在之前会被那个循环当成「不是 aarch64」丢掉。
if [ -d "$OUTDIR/simpleperf/bin/linux/aarch64" ] \
   && [ ! -e "$OUTDIR/simpleperf/bin/linux/x86_64" ]; then
  ln -s aarch64 "$OUTDIR/simpleperf/bin/linux/x86_64" \
    || die "建不了 simpleperf/bin/linux/x86_64 -> aarch64"
  ok "加了兼容软链 simpleperf/bin/linux/x86_64 -> aarch64（python 脚本写死这个名）"
fi

rmdir "$OUTDIR/prebuilt" "$OUTDIR/shader-tools" "$OUTDIR/simpleperf/bin/linux" 2>/dev/null
[ -d "$OUTDIR/toolchains/llvm/prebuilt/linux-aarch64/bin" ] \
  || die "把别的 host tag 删完，linux-aarch64 也没了 —— 这包是空的，不能发。"

# 兼容软链：linux-x86_64 -> linux-aarch64
#
# 我们的补丁 0002/0003/0004 已经让 NDK 自己算出 linux-aarch64（cmake 两个
# toolchain 文件、make_standalone_toolchain.py、init.mk 四处写死的 host tag
# 都改了）。但**第三方工具不读我们的补丁** —— 它们照着 Google 那份写死的路径
# 直接拼，找不到就判这份 NDK 不合格。真遇到过：
#
#     compgen -G "$ANDROID_HOME/ndk/*/toolchains/llvm/prebuilt/linux-x86_64/bin/clang"
#
# 一个符号链接就让两条路都通：认路径的工具够得到，认补丁的走 linux-aarch64。
if [ ! -e "$OUTDIR/toolchains/llvm/prebuilt/linux-x86_64" ]; then
  ln -s linux-aarch64 "$OUTDIR/toolchains/llvm/prebuilt/linux-x86_64" \
    || die "建不了兼容软链 linux-x86_64 -> linux-aarch64"
  ok "加了兼容软链 toolchains/llvm/prebuilt/linux-x86_64 -> linux-aarch64"
  # 这个路径现在可达了，别再让验五把它当「已经丢掉的目录」
  dropped_paths=$(printf '%s' "$dropped_paths" | tr ' ' '\n' \
    | grep -v '^toolchains/llvm/prebuilt/linux-x86_64$' | tr '\n' ' ')
fi
ok "留下 $(du -sh "$OUTDIR" | cut -f1)"
for x in $dropped; do note "丢掉 $x"; done
[ "$pb_moved" = 0 ] || note "prebuilt/ 里 $pb_moved 个跟架构无关的搬进了 linux-aarch64/"

# 顶层那四个入口写死了 prebuilt/linux-x86_64 —— 那个目录刚被丢掉，得改指向。
# （补丁 patches/ndk/ 没管这几个文件：对装了官方 NDK 的用户来说它们本来就能用，
#   是**我们的包**丢掉了 x86_64 那份才需要改，所以这是打包脚本的活，不是补丁的。）
n_fix=0; n_stub=0
for e in "$OUTDIR"/ndk-stack "$OUTDIR"/ndk-gdb "$OUTDIR"/ndk-which "$OUTDIR"/ndk-lldb; do
  [ -f "$e" ] || continue
  b=$(basename "$e")
  if [ "$HAS_LLDB" = 0 ] && { [ "$b" = ndk-gdb ] || [ "$b" = ndk-lldb ]; }; then
    # 留一个转发到不存在的东西、一跑就 127 的脚本，比明说「用不了」更糟。
    # 换成桩：把原因写在脸上，退出码非零。
    cat > "$e" <<STUB
#!/bin/sh
# 这不是 NDK 原来的 $b —— 是 android-sdk-linux-arm64 打包时换上的说明桩。
echo "$b: 这个 ARM64 包不含 host 端的 lldb，$b 暂时用不了。" >&2
echo "" >&2
echo "  缺的只是 host 那一半。**设备端的 lldb-server 已经在包里**：" >&2
echo "    toolchains/llvm/prebuilt/linux-aarch64/lib/clang/*/lib/linux/<arch>/lldb-server" >&2
echo "" >&2
echo "  host 端的 lldb 是标准 LLVM 组件，可以试系统的：" >&2
echo "    sudo apt install -y lldb" >&2
echo "    ln -s \$(command -v lldb) <NDK>/toolchains/llvm/prebuilt/linux-aarch64/bin/lldb" >&2
echo "  （$b 就是按这个路径找调试器的。没验过，成了请回报。）" >&2
exit 1
STUB
    chmod +x "$e"; n_stub=$((n_stub+1)); continue
  fi
  grep -q 'prebuilt/linux-x86_64' "$e" 2>/dev/null || continue
  sed -i 's|prebuilt/linux-x86_64|prebuilt/linux-aarch64|g' "$e" || die "改不动 $e"
  n_fix=$((n_fix+1))
done
[ "$n_fix" = 0 ] || ok "$n_fix 个顶层入口改指向 prebuilt/linux-aarch64"
[ -z "$pb_skipped" ] || note "没带进来（要 lldb，本包没编）：$pb_skipped"
[ "$n_stub" = 0 ] || note "$n_stub 个入口换成了说明桩（ndk-gdb / ndk-lldb），一跑就告诉你为什么用不了"

# 源 NDK 里可能有**指向包外**的软链 —— 打包机上为了凑合自己搭的。
# 真遇到过：prebuilt/linux-aarch64/bin/make -> /usr/bin/make。
# 这种链接在打包机上好好的，进了包就是「依赖宿主机的绝对路径」：
# 换台机器要么断链，要么歪打正着地生效 —— 两种都不该是分发包的样子。
# 包必须自足，所以一律删掉，逐个报出来（不静默）。
#
# 删 make 是安全的，依据是 build/ndk-build 自己的逻辑：
#     GNUMAKE=$ANDROID_NDK_ROOT/prebuilt/$HOST_TAG/bin/make
#     [ ! -f "$GNUMAKE" ] || GNUMAKE=$(which make)
# -f 跟随软链，所以「断链」和「文件不在」本来就走同一条路 —— 退回系统 make。
# （init.mk 里那个 HOST_MAKE 全仓库没有一处读它，是个死变量，别被它误导。）
# 万一删错了，后面验八真拿这个包编一个 .so，兜得住。
cut_links=""
while IFS= read -r l; do
  rel=${l#"$OUTDIR"/}
  r=$(readlink -f "$l" 2>/dev/null)
  if [ -z "$r" ] || [ ! -e "$l" ]; then
    cut_links="$cut_links $rel(断链)"; rm -f "$l"; continue
  fi
  case "$r/" in "$OUTDIR"/*) ;; *) cut_links="$cut_links $rel->$r"; rm -f "$l" ;; esac
done < <(find "$OUTDIR" -type l)
for x in $cut_links; do note "删掉软链 $x"; done

# patch(1) 的残留：*.orig 是**没打补丁的原版**，*.rej 是没打上的部分。
# 留在分发包里既没用又误导人。
junk=""
while IFS= read -r f; do junk="$junk ${f#"$OUTDIR"/}"; rm -f "$f"; done \
  < <(find "$OUTDIR" -type f \( -name '*.orig' -o -name '*.rej' \))
for x in $junk; do note "删掉打补丁的残留 $x"; done
# ---------------------------------------------------------------------------
step "验一：host 位置上的 ELF 全是 aarch64"
scan_tree "$OUTDIR"
[ -z "$scan_bad" ] || die "这些在 host 位置上，却不是 aarch64：$scan_bad
    这包在 ARM64 机器上解开就是坏的。"
# 数量下限：名单要是把路径写错了，一个文件都匹配不上，上面那条会「无事通过」。
# 官方原版 NDK 在这条规则下是 133 个；我们的少了 lldb 那一批，但不该少于 40。
[ "$n_host" -ge 40 ] || die "host 位置上只找到 $n_host 个 ELF，太少了（官方原版是 133）。
    要么工具链没装全，要么 is_host_pos() 的路径写错了 —— 别当它是通过。
    （40 是照官方原版的 133 定的下限。你的包要是本来就该这么少，先弄清为什么，再改这个数。）"
ok "host 位置 $n_host 个 ELF 全是 ARM aarch64（目标产物 $n_target 个，原样带着）"

step "验二：没有 host 二进制藏在目标产物的位置里"
# 「验一」靠的是位置名单，而**放行名单比检查清单危险** —— 名单漏一处就是静默放过。
# 这一条不看位置，看 ELF 里写的动态链接器：凡是要 /lib*/ld-linux-* 的都是
# Linux host 二进制，它就不该出现在「验一」放行掉的那些位置上。
# 校准：官方原版 x86_64 NDK 上这样的文件有 52 个，52 个**全**在 host 位置里，
# 一个都没漏在外面 —— 名单跟这条判据对得上，所以它报错就真是名单漏了。
[ -z "$scan_stray" ] || die "这些要 Linux 动态链接器，却待在目标产物的位置上：$scan_stray
    is_host_pos() 的名单漏了这些位置 —— 补上再打包。"
[ "$n_interp" -ge 10 ] || die "整棵树只找到 $n_interp 个动态链接的 host 二进制（官方原版 52 个）。
    工具链多半没装进来 —— 这条不算通过。"
ok "$n_interp 个动态链接的 host 二进制，全在 host 位置里"

step "验三：host 位置上的静态库也得是 aarch64"
# file(1) 对 .a 只说「ar archive」，不说里头是什么架构 —— 上面两条都盖不到
# libc++.a 这种。这一条把成员掏出来问。
if command -v ar >/dev/null 2>&1; then
  abad=""; na=0; nskip=0
  while IFS= read -r f; do
    rel=${f#"$OUTDIR"/}
    is_host_pos "$rel" || continue
    case "$(file -b "$f" 2>/dev/null)" in *"ar archive"*) ;; *) continue ;; esac
    # 头几个成员未必是目标文件（可能是 LICENSE 之类），挨个试到碰上 ELF 为止
    judged=0
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      at=$(ar p "$f" "$m" 2>/dev/null | file -b - 2>/dev/null)
      case "$at" in *ELF*) ;; *) continue ;; esac
      judged=1
      case "$at" in *"ARM aarch64"*) ;; *) abad="$abad $rel[$(printf '%s' "$at" | cut -d, -f2 | tr -d ' ')]" ;; esac
      break
    done < <(ar t "$f" 2>/dev/null | head -5)
    if [ "$judged" = 1 ]; then na=$((na+1)); else nskip=$((nskip+1)); fi
  done < <(find "$OUTDIR" -type f -name '*.a')
  [ -z "$abad" ] || die "这些 host 位置上的静态库不是 aarch64：$abad"
  # 「一个都没查到」跟「查过都对」得分得开 —— 说成同一句就是那条老毛病。
  # 我们的工具链 lib/ 那一层确实可能一个 .a 都没有（官方原版有 3 个：
  # libc++.a / libc++abi.a / libbolt_rt_instr.a），那是事实，不是通过。
  if [ "$na" = 0 ]; then
    warn "host 位置上一个静态库都没找到，**这条检查没判过任何东西**。"
    note "（官方原版 lib/ 那一层有 3 个 .a。我们的没有就是没有 —— 但别把它当「查过了都对」。）"
  else
    ok "$na 个 host 静态库，架构都对"
  fi
  [ "$nskip" = 0 ] || note "另有 $nskip 个 .a 前 5 个成员里没有目标文件，**没判**。"
else
  warn "这台没有 ar(1)，**host 位置上的 .a 一个都没查**。"
  note "不是「查过了没问题」，是「没查」。装 binutils 再打一次包才算数。"
fi

step "验四：包里没有跑到包外面的软链"
# 摆目录那一步已经把越界的软链删掉了，所以这一条现在是**那段删除逻辑的兜底**：
# 它要是还报，说明该删的没删干净。
# 薄壳工具链就是拿软链搭的；拷出来的包要是还留着指向机器上别处的链接，
# 解压到别人机器上就是断链。官方原版 NDK 里 35 个软链，绝对路径 0、断链 0 ——
# 这条在原版上是干净通过的，所以它报错就真是我们弄坏的。
esc=""; nl=0
while IFS= read -r l; do
  nl=$((nl+1)); rel=${l#"$OUTDIR"/}
  r=$(readlink -f "$l" 2>/dev/null)
  { [ -z "$r" ] || [ ! -e "$l" ]; } && { esc="$esc $rel(断链)"; continue; }
  case "$r/" in "$OUTDIR"/*) ;; *) esc="$esc $rel(指向包外:$r)" ;; esac
done < <(find "$OUTDIR" -type l)
[ -z "$esc" ] || die "这些软链在包里待不住：$esc"
ok "$nl 个软链，都指在包里"

# ---------------------------------------------------------------------------
step "验五：没有文件还指着被丢掉的目录"
# **这次就栽在这儿。** prebuilt/ 曾经被整个丢掉，而 NDK 顶层的
# ndk-stack / ndk-gdb / ndk-which / ndk-lldb 都写死转发到 prebuilt/linux-x86_64/bin/，
# 四个入口全变成 127（not found）—— 上面四道检查一道都没抓到，因为它们
# 只看 ELF 和软链，**没人查「东西丢完了，谁还指着它」**。
#
# 通用形式：删掉任何东西之后，扫一遍还有没有人引用它。
# 只查**会被执行的**文本文件（带可执行位的）：文档里提一句路径是说明，不是引用。
# 这条分界在官方原版 NDK 上校准过 —— 那四个被丢的路径，可执行引用只有上面那
# 四个入口，文档命中的只有 simpleperf/doc/scripts_reference.md。
ref=""; n_ref=0
for pth in $dropped_paths; do
  n_ref=$((n_ref+1))
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -x "$f" ] || continue                       # 文档不算
    case "$f" in "$OUTDIR/$pth"/*) continue ;; esac  # 它自己目录里的，已经跟着丢了
    ref="$ref ${f#"$OUTDIR"/}->$pth"
  done < <(grep -rl --binary-files=without-match -F "$pth" "$OUTDIR" 2>/dev/null)
done
[ -z "$ref" ] || die "这些**可执行**文件还指着已经丢掉的目录：$ref
    丢东西之前先想一句：谁在引用它。"
[ "$n_ref" -ge 1 ] || die "一个被丢掉的目录都没记下来，这条检查等于没做。"
ok "$n_ref 个丢掉的目录，没有可执行文件再指着它们"

step "验六：包里的 host 二进制真的能跑"
# 第五节第 2 条：「文件存在」不是验收。上面三条只问了 file(1)「你是什么架构」，
# 那正是 aapt2 那次栽的地方 —— 文件在、有可执行位、exec 出来是 126。
# 判据跟 tests/common.sh 的 runs() 一样：退出码 < 126。
#
# 只跑 bin/ 底下的。lib/ 里的 .so 也带 +x，可它们没有入口点，跑起来必 segfault
# （退出码 139 > 126），拿它们当「跑不起来」是误报。
if [ "$(uname -m)" != aarch64 ] && [ "$(uname -m)" != arm64 ]; then
  note "这台是 $(uname -m)，包里是 aarch64 的二进制，跑不了 —— 跳过。"
  note "**这一条没验过。** 到 ARM64 机器上重跑本脚本才算数（第五节第 1 条）。"
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
    case "/$rel" in */bin/*) ;; *) continue ;; esac
    is_host_pos "$rel" || continue
    [ -x "$f" ] && [ ! -L "$f" ] || continue
    case "$(file -b "$f" 2>/dev/null)" in *ELF*) ;; *) continue ;; esac
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
  # 又是那条：名单写错路径的话，一个都匹配不上，上面两条会「无事通过」
  [ "$n_ran" -ge 10 ] || die "只跑到了 $n_ran 个 host 二进制（官方原版 bin/ 里有 38 个）。
    工具链多半没装进来 —— 这条不算通过。"
  ok "$n_ran 个 host 二进制真跑过一遍，都能起来"
fi

step "写 PROVENANCE.txt"
CLANGV=$("$TC/bin/clang" --version 2>/dev/null | sed -n '1s/.*clang version \([0-9.]*\).*/\1/p')
# 出处里写个「?」等于没写 —— 走到这一步 clang 是跑得起来的（验五刚跑过），
# 读不出版本号说明 --version 的样子跟预期不一样，那就得看一眼再写。
[ -n "$CLANGV" ] || die "读不出 $TC/bin/clang 的版本号，PROVENANCE.txt 里会是个问号。
    自己看一眼：$TC/bin/clang --version"
{
  echo "android-sdk-linux-arm64 —— ARM64 Linux 版 Android NDK $VER"
  echo
  # **只写值，不写「值是怎么来的」**：同一个时间，设了 SOURCE_DATE_EPOCH 和
  # 靠 HEAD 推出来的，写进去的字不一样，包的 sha256 就不一样 —— 而文档让人
  # 「checkout tag 重打」正是后一种，等于文档里的复现步骤对不上已公布的校验和。
  # 差点就这么发出去了。$REPRO_SRC 只往 stdout 打，不进包。
  echo "生成时间（UTC）: $REPRO_STAMP   （SOURCE_DATE_EPOCH=$REPRO_EPOCH）"
  echo "打包机器      : $(uname -m)"
  echo
  echo "== 自己编的 =="
  echo "  toolchains/llvm/prebuilt/linux-aarch64/{bin,lib,libexec}   clang ${CLANGV:-?} + lld + llvm-*"
  echo "      源码 android.googlesource.com/toolchain/llvm-project 分支 llvm-r522817"
  echo "      配方 tools/build-llvm.sh（cmake flags 抄 toolchain/llvm_android 的 build.py）"
  echo "  toolchains/llvm/prebuilt/linux-aarch64/python3             CPython ${PYVER:-?}"
  echo "      源码 AOSP external/python/cpython3 @ platform-tools-35.0.2"
  echo "      配方 tools/build-python.sh"
  echo
  echo "== 从官方 NDK $VER 原样拿的（目标产物或跟架构无关）=="
  echo "  toolchains/llvm/prebuilt/linux-aarch64/sysroot    bionic 的头文件和库（5 个架构）"
  echo "  toolchains/llvm/prebuilt/linux-aarch64/lib/clang  compiler-rt 的目标运行时"
  echo "  toolchains/llvm/prebuilt/linux-aarch64/musl       musl 目标的运行时"
  echo "  sources/ build/ meta/ python-packages/ wrap.sh"
  echo "  toolchains/llvm/prebuilt/linux-x86_64 -> linux-aarch64（软链）"
  echo "      补丁让 NDK 自己算得出 host tag，但第三方工具会直接拼写死的路径"
  echo "  prebuilt/linux-aarch64/bin/                       $(ls "$OUTDIR/prebuilt/linux-aarch64/bin" 2>/dev/null | tr '\n' ' ')"
  echo "      都是脚本 / zipapp，跟架构无关，从官方那份 linux-x86_64/bin 搬过来的"
  echo "      （里面写死的 prebuilt/linux-x86_64 路径跟着改成了 linux-aarch64）"
  echo "  simpleperf/bin/android/<abi>/                     跑在设备上的"
  if [ -x "$OUTDIR/simpleperf/bin/linux/aarch64/simpleperf" ]; then
    echo "  simpleperf/bin/linux/aarch64/simpleperf           **自己编的**（host 那半）"
    echo "      官方只发 x86_64。源码 AOSP system/extras/simpleperf，静态 bionic。"
    echo "      （下面「丢掉的」里那条 simpleperf/bin/linux/x86_64 指的是**官方那份**，"
    echo "       被这份换掉了；现在那个名字是一条指向 aarch64 的软链。）"
    echo "      x86_64 -> aarch64 是软链：它自己的 python 脚本把 host 目录写死成 x86_64。"
    echo "      **缺 libsimpleperf_report.so**（python 用 ctypes 加载的那个共享库）——"
    echo "      它要进 CPython 进程，一个进程里混不了 bionic 和 glibc，是另一条线。"
    echo "      曾经有一处真缺陷：本机录出来的 perf.data 它自己读不回（meta info 里"
    echo "      几个 android_* 键在 Linux 上取不到值，而读的那一侧拒绝空值）。"
    echo "      **已经修了** —— patches/simpleperf/0001-skip-empty-meta-info.patch"
    echo "      让写的那一侧跳过空值。这个包里实测：record 到 1,368 个样本，"
    echo "      report 读回 Samples: 1368，退出码 0。"
    echo "      **读设备录的文件那条仍然没验**（缺真机）。"
  fi
  echo "  NOTICE, NOTICE.toolchain, CHANGELOG.md, source.properties"
  echo
  echo "== 改过的 =="
  echo "  build/core/init.mk, build/cmake/*.cmake, build/tools/*  —— 见本仓库 patches/ndk/"
  echo "  0001-0004 让 NDK 在 aarch64 上算出 linux-aarch64 这个 host tag"
  echo "  0005      HOST_PYTHON 找不到时报错，不再静默降级"
  echo
  if [ "$n_stub" != 0 ]; then
    echo "== 换成说明桩的 =="
    echo "  ndk-gdb, ndk-lldb —— **不是 NDK 原来那两个**，是打包时换上的桩，"
    echo "  一跑就说明为什么用不了。原因：ndkgdb.pyz 里 get_llvm_host_name()"
    echo "  写死 return \"linux-x86_64\"，而且它要 liblldb.so —— 本包没编 lldb。"
    echo "  留一个一跑就 127 的转发脚本，比明说用不了更糟，所以换掉。"
    echo
  fi
  echo "== 打包时删掉的 =="
  for x in $cut_links; do echo "  软链 $x（指向包外，包必须自足）"; done
  for x in $junk;      do echo "  $x（patch 的残留）"; done
  [ -n "$cut_links$junk" ] || echo "  （没有）"
  echo
  echo "== 没放进来的 host 二进制 =="
  for x in $dropped; do echo "  $x"; done
  echo "  prebuilt/<tag>/  里的 make / yasm / vsyasm / ytasm（x86 二进制）和 yasm 的"
  echo "      include lib share。ndk-build 找不到 prebuilt 的 make 会退回系统的，实测能用。"
  # **数字必须是数出来的**（$pb_moved），不能写死。原先这里写死「那 5 个」，
  # 而 HAS_LLDB 判据修好之后 ndk-gdb / ndkgdb.pyz 不再搬了，实际是 3 个 ——
  # 包里就印着一句假话。2026-08-29 实测撞上。
  echo "      同目录下跟架构无关的那 $pb_moved 个已经搬进 prebuilt/linux-aarch64/bin/，"
  [ -z "$pb_skipped" ] || \
    echo "      （$pb_skipped 没搬：本包没有 host 端 lldb，搬进来就是「文件在、一跑就错」）"
  echo "      顶层 ndk-stack / ndk-gdb / ndk-which / ndk-lldb 的转发路径也跟着改了。"
  echo "  shader-tools/ glslc / spirv-*，没有 aarch64 版；编 Vulkan shader 才用得上"
  echo "  lldb / clang-tidy / clangd 也不在（见本仓库 README 第四节）"
  echo
  echo "这不是 Google 发布的包，也不冒充。"
} > "$OUTDIR/PROVENANCE.txt"
ok "$OUTDIR/PROVENANCE.txt"

# 出处标在**新加的一行**里，**不动 Pkg.Desc**。
#
# 头一版是 `sed -i 's/^Pkg.Desc *=.*/… rebuilt by …/'`，把出处写进 Pkg.Desc。
# 那一改让**所有走 CMake 的 Gradle 工程全部编不了** —— NDK 自己的
# build/cmake/android-legacy.toolchain.cmake 拿这个正则读版本号：
#
#     "^Pkg\\.Desc = Android NDK\nPkg\\.Revision = ([0-9]+)\\.([0-9]+)\\.([0-9]+)…"
#
# 它要求**文件头两行一字不差**。Pkg.Desc 后面多一个字，整条 CMake 路径就报
# 「Failed to parse Android NDK revision」。ndk-build 那条路不读这个文件，
# 所以八道检查、真机出 APK、端到端测试**一道都没碰到**，第一次跑
# ./gradlew 才炸出来。**改一个自认为是说明文字的字段，没人查谁在解析它。**
{
  # 头两行必须是官方原样，追加的键放在后面
  head -2 "$OUTDIR/source.properties"
  tail -n +3 "$OUTDIR/source.properties"
  echo "Pkg.Provenance = rebuilt by android-sdk-linux-arm64 for linux/aarch64; see PROVENANCE.txt"
} > "$OUTDIR/source.properties.new" && mv "$OUTDIR/source.properties.new" "$OUTDIR/source.properties"

# 检查不能只问「改上了吗」，要问「改完 NDK 自己还认得吗」。判据直接从
# toolchain 文件里现读，这样它哪天变了这里跟着变，不会各写各的。
tc_re=$(sed -n 's/^ *"\(\^Pkg\\\\\.Desc[^"]*\)".*/\1/p' \
        "$OUTDIR/build/cmake/android-legacy.toolchain.cmake" | head -1)
[ -n "$tc_re" ] || die "在 android-legacy.toolchain.cmake 里找不到那条读版本号的正则 —— 它换写法了，这里的检查得跟着改"
want="Pkg.Desc = Android NDK"
[ "$(head -1 "$OUTDIR/source.properties")" = "$want" ] \
  || die "source.properties 第一行不是「$want」，CMake 那条路会挂。
    toolchain 文件要的是：$tc_re"
_sp=$(head -2 "$OUTDIR/source.properties" | tail -1)   # 不走管道到 grep -q
grep -q '^Pkg\.Revision = [0-9]' <<<"$_sp" \
  || die "source.properties 第二行不是 Pkg.Revision —— 同上，CMake 会挂"
grep -q '^Pkg\.Provenance = ' "$OUTDIR/source.properties" || die "Pkg.Provenance 那行没加上"
ok "source.properties 标了出处，且头两行仍是 CMake toolchain 要的原样"

# ---------------------------------------------------------------------------
step "验七：顶层那几个入口脚本真能跑"
# 验六只扫 ELF —— ndk-stack / ndk-gdb / ndk-which 是 shell 脚本，它扫不到，
# 而**它们正是这次被丢坏的那批**。判据同验六：退出码 < 126。
# 127 单独点名：那是「转发过去的目标不在」，也就是这次的病。
if [ "$(uname -m)" != aarch64 ] && [ "$(uname -m)" != arm64 ]; then
  note "这台是 $(uname -m)，入口脚本会去调工具链里 aarch64 的 python3 —— 跳过。"
  note "**这一条没验过。** 到 ARM64 机器上重跑本脚本才算数（第五节第 1 条）。"
else
  n_ent=0; bad_ent=""
  for e in ndk-stack ndk-gdb ndk-which ndk-lldb; do
    [ -f "$OUTDIR/$e" ] && [ -x "$OUTDIR/$e" ] || continue
    n_ent=$((n_ent+1))
    timeout 20 "$OUTDIR/$e" --help </dev/null >/dev/null 2>&1; rc=$?
    case "$rc" in
      127) bad_ent="$bad_ent $e(127，转发的目标不在)" ;;
      126) bad_ent="$bad_ent $e(126，跑不了)" ;;
      124) bad_ent="$bad_ent $e(卡住，20 秒没退)" ;;
    esac
  done
  [ -z "$bad_ent" ] || die "这几个顶层入口坏了：$bad_ent
    多半是它们写死的转发路径指向了已经丢掉的目录。"
  [ "$n_ent" -ge 3 ] || die "只找到 $n_ent 个顶层入口（原版有 4 个：ndk-stack/gdb/which/lldb）。
    这条不算通过。"
  ok "$n_ent 个顶层入口真跑过一遍，都能起来"
fi

step "验八：拿这个包真编一个 .so"
# **判据是「用这个包」，不是「用机器上装的那个 NDK」** —— 所以
# ANDROID_NDK_HOME 指到 $OUTDIR，ndk-build 也从 $OUTDIR 里拿。
if [ "$(uname -m)" != aarch64 ] && [ "$(uname -m)" != arm64 ]; then
  note "这台是 $(uname -m)，包里是 aarch64 的工具链，跑不了 —— 跳过。"
  note "**这一条没验过。** 到 ARM64 机器上重跑本脚本才算数（第五节第 1 条）。"
else
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  mkdir -p "$T/jni"
  printf 'int twenty(void){return 20;}\nint twentytwo(void){return 22;}\n' > "$T/jni/x.c"
  printf 'LOCAL_PATH := $(call my-dir)\ninclude $(CLEAR_VARS)\nLOCAL_MODULE := x\nLOCAL_SRC_FILES := x.c\ninclude $(BUILD_SHARED_LIBRARY)\n' > "$T/jni/Android.mk"
  ( cd "$T" && ANDROID_NDK_HOME="$OUTDIR" "$OUTDIR/ndk-build" NDK_PROJECT_PATH="$T" \
      APP_ABI=arm64-v8a NDK_APPLICATION_MK=/dev/null >"$T/log" 2>&1 ) \
    || { tail -20 "$T/log" >&2; die "拿这个包编不出东西"; }
  SO="$T/libs/arm64-v8a/libx.so"
  [ -f "$SO" ] || die "ndk-build 没报错，但 $SO 不在"
  f=$(file -b "$SO")
  case "$f" in *"ARM aarch64"*) ;; *) die "编出来的不是 aarch64：$f" ;; esac
  # 编出来的必须是**目标**产物：Android 的 .so 不带 Linux INTERP
  case "$f" in *"interpreter /lib"*) die "编出来的是个 Linux host 库，不是 Android 的 —— 工具链的 target 默认值不对" ;; esac
  ok "ndk-build 用这个包编出了 libx.so（$(stat -c%s "$SO") 字节）"
fi

step "验九：拿这个包走一遍 CMake"
# 验八走的是 ndk-build，**它不读 source.properties，也不碰 build/cmake/**。
# CMake 是另一条完全独立的路，AGP 的 externalNativeBuild 走的就是它。
# 这条检查是补票来的：Pkg.Desc 后面多写了几个字，
# android-legacy.toolchain.cmake 那条「头两行一字不差」的正则就匹配不上，
# **所有走 CMake 的 Gradle 工程全挂**，而当时八道检查一道都没红。
if [ "$(uname -m)" != aarch64 ] && [ "$(uname -m)" != arm64 ]; then
  note "这台是 $(uname -m)，包里是 aarch64 的工具链，跑不了 —— 跳过。"
  note "**这一条没验过。**"
elif ! command -v cmake >/dev/null || ! command -v ninja >/dev/null; then
  # 「没装」和「验过了」必须分开说 —— 第五节第 2 条。
  warn "这台没有 cmake(1) 或 ninja(1)，**CMake 那条路一步都没验**。"
  note "装：sudo apt install -y cmake ninja-build"
else
  T2=$(mktemp -d)
  printf 'int f(void){return 42;}\n' > "$T2/x.c"
  printf 'cmake_minimum_required(VERSION 3.10)\nproject(x C)\nadd_library(x SHARED x.c)\n' > "$T2/CMakeLists.txt"
  if cmake -S "$T2" -B "$T2/b" -G Ninja -DCMAKE_MAKE_PROGRAM="$(command -v ninja)" \
       -DCMAKE_TOOLCHAIN_FILE="$OUTDIR/build/cmake/android.toolchain.cmake" \
       -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-24 >"$T2/log" 2>&1 \
     && cmake --build "$T2/b" >>"$T2/log" 2>&1 && [ -f "$T2/b/libx.so" ]; then
    f2=$(file -b "$T2/b/libx.so")
    case "$f2" in
      *"ARM aarch64"*) ok "CMake 用这个包的 toolchain 文件编出了 arm64-v8a 的 .so" ;;
      *) rm -rf "$T2"; die "CMake 编出来了但不是 aarch64：$f2" ;;
    esac
  else
    sed -n '/CMake Error/,+6p' "$T2/log" | head -12 | sed 's/^/      /' >&2
    rm -rf "$T2"
    die "CMake 走不通这个包。最常见的原因是 source.properties 被改动过 ——
    android-legacy.toolchain.cmake 要求头两行一字不差。"
  fi
  rm -rf "$T2"
fi

step "打包"
if [ "$OURS_ONLY" = 1 ]; then
  step "裁成「只含我们编的」"
  # 官方 NDK 的内容（sysroot、build/、sources/、meta/、prebuilt/…）受 Android SDK
  # 的许可条款约束，我们不再分发 —— 装的时候由 tools/install.sh 从 Google 取。
  # **留下的必须全是我们自己产出的**：
  #   toolchains/llvm/prebuilt/linux-aarch64/  我们编的 clang/lld/llvm-* 和 python3
  #       但要去掉 sysroot/ 和 lib/clang/ —— 那两个是从官方 x86_64 那份拷进来的
  #   simpleperf/bin/linux/aarch64/            我们编的 host 那半
  #   ndk-gdb / ndk-lldb                       我们写的说明桩
  #   PROVENANCE.txt                           我们写的
  keep_tc="$OUTDIR/toolchains/llvm/prebuilt/linux-aarch64"
  rm -rf "$keep_tc/sysroot" "$keep_tc/lib/clang"
  find "$OUTDIR" -mindepth 1 -maxdepth 1 \
       ! -name toolchains ! -name simpleperf ! -name PROVENANCE.txt \
       ! -name ndk-gdb ! -name ndk-lldb -exec rm -rf {} + 2>/dev/null || true
  find "$OUTDIR/toolchains" -mindepth 1 -maxdepth 1 ! -name llvm -exec rm -rf {} + 2>/dev/null || true
  find "$OUTDIR/toolchains/llvm" -mindepth 1 -maxdepth 1 ! -name prebuilt -exec rm -rf {} + 2>/dev/null || true
  find "$OUTDIR/toolchains/llvm/prebuilt" -mindepth 1 -maxdepth 1 ! -name linux-aarch64 -exec rm -rf {} + 2>/dev/null || true
  find "$OUTDIR/simpleperf" -mindepth 1 -maxdepth 1 ! -name bin -exec rm -rf {} + 2>/dev/null || true
  find "$OUTDIR/simpleperf/bin" -mindepth 1 -maxdepth 1 ! -name linux -exec rm -rf {} + 2>/dev/null || true
  ok "裁完 $(du -sh "$OUTDIR" | cut -f1)（原来整包 1.9G 左右）"
  note "少掉的那些由 install.sh 从官方 NDK 取，并用 tools/patch-ndk.sh 打上 host tag 的补丁"
fi

step "归一化 python 的 __pycache__"
# 这些 .pyc **不是从供体拷进来的，是上面那些验证步骤跑这个 python 时顺手生成的**。
# 它们有两处不确定性，两处都实测确认过：
#   1. 默认失效判据是「源文件的 mtime + 大小」，mtime 每次打包都不同（差在第 9 字节）；
#   2. .pyc 里还嵌着编译时的**绝对路径**，两次打包换个目录就不同（差在第 222 字节）。
# 第一次验 NDK 包的可复现性就是栽在这儿：两次 sha256 不同，diff 出来全是 .pyc。
#
# 官方包里也带 46 个 .pyc，所以不整个删掉，而是重新编一遍：
#   --invalidation-mode unchecked-hash  判据从 mtime 换成源文件哈希（PEP 552）
#   -d <固定路径>                        把嵌进去的路径钉死
# 两条都做完，.pyc 的内容就只由 .py 源文件决定（单独验过：不同目录、不同 mtime，
# 编出来逐字节一致）。
PYROOT="$OUTDIR/toolchains/llvm/prebuilt/linux-aarch64/python3"
if [ -x "$PYROOT/bin/python3" ]; then
  pyc_before=$(find "$PYROOT" -name '*.pyc' | wc -l)
  pycdirs=$(cd "$PYROOT" && find . -name __pycache__ -type d | sed 's|/__pycache__$||' | sort)
  find "$PYROOT" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
  for d in $pycdirs; do
    # -l  只编这一层，不往下递归（原来有 .pyc 的就是这些目录）
    # -f  **必须有**：compileall 会跳过它认为已经最新的 .pyc，而解释器自己启动
    #     导入 stdlib 时刚写过一批 timestamp 判据的（enum/functools/locale…），
    #     不加 -f 就正好把它们留下来 —— 第一版漏了这个，包照样不可复现，
    #     从包里掏出 .pyc 看 PEP 552 标志位才发现（flags=0）。
    # PYTHONDONTWRITEBYTECODE=1 从源头堵住解释器自己那批（compileall 是显式
    #     写文件，不受这个变量影响 —— 单独验过）。
    PYTHONDONTWRITEBYTECODE=1 "$PYROOT/bin/python3" -m compileall -q -l -f \
        --invalidation-mode unchecked-hash \
        -d "/python3/${d#./}" "$PYROOT/$d" >/dev/null 2>&1 || true
  done
  # 判据真的换过来了吗 —— 别只看它跑完没报错。
  bad_pyc=$("$PYROOT/bin/python3" - "$PYROOT" <<'PYEOF'
import glob, struct, sys, os
bad = 0
for f in glob.glob(os.path.join(sys.argv[1], "**", "*.pyc"), recursive=True):
    with open(f, "rb") as fh:
        if not (struct.unpack("<I", fh.read(8)[4:8])[0] & 1):
            bad += 1
print(bad)
PYEOF
)
  [ "${bad_pyc:-1}" = 0 ] || die "包里还有 $bad_pyc 个 .pyc 是 timestamp 判据的，包不可复现。
    （PEP 552 的标志位在第 5-8 字节；hash 判据是最低位为 1。）"
  pyc_after=$(find "$PYROOT" -name '*.pyc' | wc -l)
  ok "$pyc_before 个 .pyc 重编成 $pyc_after 个（hash 判据 + 路径钉死，跟打包时间和目录无关）"
else
  note "包里没有自带的 python3，这一步跳过"
fi

# **不能写成 ${OURS_ONLY:+-ours}**：OURS_ONLY=0 也是非空，全量包会被叫成 -ours。
sfx=""; [ "$OURS_ONLY" = 1 ] && sfx="-ours"
TAR="$WORK/android-ndk-$VER-linux-aarch64$sfx.tar.gz"
rm -f "$TAR"
repro_tar "$OUTROOT" "$TAR" || die "打包失败"
ok "$TAR（$(du -h "$TAR" | cut -f1)）"

step "好了"
note "目录：$OUTDIR"
note "装法：tar -C \$ANDROID_HOME -xzf $TAR"
note "      （解压出来是 ndk/$VER/，跟 sdkmanager 装的位置一样）"
note ""
note "**没包含**：prebuilt/ 里的 make / yasm（x86 的，退回系统的即可；同目录下跟架构"
note "无关的 $pb_moved 个脚本已搬进 prebuilt/linux-aarch64/）、shader-tools/（没有 aarch64 版）、"
if [ -x "$OUTDIR/simpleperf/bin/linux/aarch64/simpleperf" ]; then
  note "（simpleperf 的 host 那半**在**这个包里了，见 PROVENANCE.txt）"
else
  note "simpleperf 的 host 那半。清单和理由在包里的 PROVENANCE.txt。"
fi
