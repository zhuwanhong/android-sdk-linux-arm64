#!/usr/bin/env bash
# 复现 README 第一、二节的每条事实。
#
# 这个项目的全部理由建立在几条可验证的事实上。事实会变——Google 随时可能
# 补上 ARM Linux 构建。所以这些断言必须能一键重跑，而不是躺在 README 里。
#
# 档位：
#   PASS   断言成立
#   INFO   清单类事实（数量随 NDK 版本和 host OS 变，不判红）
#   BLOCK  挡住移植的上游现状。不是回归——修掉它们就是这个项目的活。
#   FAIL   断言不成立，或验不了
#
# 退出码：
#   0   前提仍然成立（项目仍有意义）
#   10  Google 已经发 linux/aarch64 包 —— 前提失效，这个项目可以关掉了（好消息）
#   1   某条断言不成立或无法验证
#
# 用法：  tools/verify-claims.sh [ndk 路径]

set -uo pipefail

MANIFEST_URL="${MANIFEST_URL:-https://dl.google.com/android/repository/repository2-3.xml}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

rc=0
blockers=0
pass()  { printf '  \033[32mPASS\033[0m   %s\n' "$1"; }
fail()  { printf '  \033[31mFAIL\033[0m   %s\n' "$1"; rc=1; }
skip()  { printf '  \033[33mSKIP\033[0m   %s\n' "$1"; }
info()  { printf '  \033[36mINFO\033[0m   %s\n' "$1"; }
block() { printf '  \033[35mBLOCK\033[0m  %s\n' "$1"; blockers=$((blockers + 1)); }
note()  { printf '         %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

PY=$(command -v python3 || command -v python) || { echo "需要 python3"; exit 1; }

head_ "0. 这台机器"
note "$(uname -s) $(uname -m)"
case "$(uname -m)" in
  aarch64|arm64) ;;
  *) note "注意：不是 aarch64。第五节：在 x86 上「编过了」什么都不证明。" ;;
esac

# ------------------------------------------------------------------ 1.1
head_ "1.1 Google 的仓库里有没有 ARM Linux 的包"

if ! curl -sSf -o "$WORKDIR/repo.xml" "$MANIFEST_URL"; then
  fail "拉不到 $MANIFEST_URL"
else
  # 按 <archive> 元素解析，不用正则配对：正则只匹配 host-arch 紧跟 host-os
  # 的情况，会漏掉 host-arch 缺省的历史条目（那些其实也是 x86_64）。
  "$PY" - "$WORKDIR/repo.xml" <<'PYEOF' > "$WORKDIR/counts.txt"
import sys, collections, xml.etree.ElementTree as ET
tag = lambda e: e.tag.split('}')[-1]
counts, arm = collections.Counter(), []
for pkg in ET.parse(sys.argv[1]).getroot().iter():
    if tag(pkg) != 'remotePackage':
        continue
    for ar in pkg.iter():
        if tag(ar) != 'archive':
            continue
        kv = {tag(k): (k.text or '').strip() for k in ar}
        os_ = kv.get('host-os', '<any>')
        arch = kv.get('host-arch', '<any>' if os_ == '<any>' else '<unset>')
        counts[(os_, arch)] += 1
        if arch in ('aarch64', 'arm64'):
            arm.append((os_, pkg.get('path')))
for (o, a), n in counts.most_common():
    print(f"COUNT\t{n}\t{o}\t{a}")
for o, p in sorted(set(arm)):
    print(f"ARM\t{o}\t{p}")
PYEOF

  if [ ! -s "$WORKDIR/counts.txt" ]; then
    fail "manifest 解析不出任何 archive —— 格式可能变了，去看 $MANIFEST_URL"
  else
    awk -F'\t' '$1=="COUNT"{printf "         %5d  %-8s %s\n", $2, $3, $4}' "$WORKDIR/counts.txt"

    linux_arm=$(awk -F'\t' '$1=="ARM" && $2=="linux"'  "$WORKDIR/counts.txt" | grep -c .)
    mac_arm=$(awk   -F'\t' '$1=="ARM" && $2=="macosx"' "$WORKDIR/counts.txt" | grep -c .)
    mac_arm_ar=$(awk -F'\t' '$1=="COUNT" && $3=="macosx" && $4=="aarch64"{print $2}' "$WORKDIR/counts.txt")

    if [ "$mac_arm" -eq 0 ]; then
      fail "macOS 的 aarch64 包也没有了 —— manifest 结构变了，这个脚本的判断不可信"
    else
      pass "macOS 有 $mac_arm 个 aarch64 包（${mac_arm_ar:-?} 个 archive）：工具链本身编得到 ARM"
    fi

    if [ "$linux_arm" -eq 0 ]; then
      pass "linux/aarch64 包数 = 0 —— 前提仍然成立"
    else
      printf '  \033[32m前提失效\033[0m  Google 现在发 linux/aarch64 包了：\n'
      awk -F'\t' '$1=="ARM" && $2=="linux"{print "         " $3}' "$WORKDIR/counts.txt"
      note "先确认它们覆不覆盖 build-tools 和 NDK。如果覆盖了，这个项目可以关掉。"
      exit 10
    fi
  fi
fi

# ------------------------------------------------------------------ 找 NDK
NDK="${1:-}"
if [ -z "$NDK" ]; then
  for c in "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK:-}" \
           "${ANDROID_HOME:-}"/ndk/* "${ANDROID_SDK_ROOT:-}"/ndk/* \
           "${ANDROID_HOME:-}"/ndk-bundle; do
    if [ -n "$c" ] && [ -d "$c/toolchains/llvm/prebuilt" ]; then NDK="$c"; break; fi
  done
fi

if [ -z "$NDK" ] || [ ! -d "$NDK/toolchains/llvm/prebuilt" ]; then
  head_ "2. NDK 的移植面"
  skip "没找到 NDK。传路径：tools/verify-claims.sh /path/to/ndk"
  exit $rc
fi

head_ "2. NDK 的移植面（$(basename "$NDK")）"

# host tag 不写死：这个脚本自己就得能在任何 host 上跑
# 参照用的 host tag：要挑「货真价实的那份」，不能 ls | head -1。
# tools/make-shim-toolchain.sh 搭出来的薄壳会留一个 .shim-generated 标记，
# 那份里 sysroot 和 lib/clang 都是软链，拿它量体积会得出负数。
# 判定一份 prebuilt 是不是薄壳：标记文件，或者结构上就是借来的
#（真工具链的 sysroot 是实打实的目录；薄壳的是软链到别人那份）
is_shim() {
  [ -e "$1/.shim-generated" ] && return 0          # 本仓库生成的标记
  [ -L "$1/sysroot" ] && return 0                  # sysroot 是借来的
  [ -L "$1/lib/clang" ] && return 0                # resource dir 是借来的
  return 1
}

HOST_TAG=
for d in "$NDK"/toolchains/llvm/prebuilt/*/; do
  [ -d "$d" ] || continue
  is_shim "${d%/}" && continue
  HOST_TAG=$(basename "$d"); break
done
[ -n "$HOST_TAG" ] || HOST_TAG=$(ls -1 "$NDK/toolchains/llvm/prebuilt" | head -1)
PREBUILT="$NDK/toolchains/llvm/prebuilt/$HOST_TAG"
note "参照 host tag: $HOST_TAG"

# --- 2a. 哪些目录跟 host 架构有关
#     README 第二节说只有一个。r27 上是四个：另外三个体量小，但 make 在
#     prebuilt/ 底下，而 ndk-build 要用 make。
#     本仓库搭的薄壳也会出现在这里，单独标出来——它是产出，不是待办。
hostdirs=$(find "$NDK" -maxdepth 4 -type d 2>/dev/null \
             | grep -E '/(linux|darwin|windows)[^/]*$' \
             | grep -v '/sysroot/' | grep -v '/build/core/' | sort)
n_hostdirs=$(printf '%s\n' "$hostdirs" | grep -c .)
n_shim=0
for d in $hostdirs; do is_shim "$d" && n_shim=$((n_shim + 1)); done
if [ "$n_hostdirs" -eq 0 ]; then
  fail "一个 host 目录都没找到 —— NDK 结构变了，第二节的结论要重看"
else
  info "$((n_hostdirs - n_shim)) 个目录跟 host 架构有关（要重编）$([ "$n_shim" -gt 0 ] && echo "，另有 $n_shim 个是本仓库搭的薄壳")："
  printf '%s\n' "$hostdirs" | while IFS= read -r d; do
    if is_shim "$d"; then
      note "$(printf '%9s  $NDK%s' "薄壳" "${d#"$NDK"}")"
    else
      sz=$(du -sm "$d" 2>/dev/null | cut -f1)
      note "$(printf '%6s MB  $NDK%s' "${sz:-?}" "${d#"$NDK"}")"
    fi
  done
fi

# --- 2b. sysroot 跟 host 无关
lib=$(find "$PREBUILT/sysroot/usr/lib/aarch64-linux-android" -name libc.so 2>/dev/null | head -1)
if [ -z "$lib" ]; then
  skip "sysroot 里没找到 aarch64-linux-android/libc.so"
elif ! command -v file >/dev/null; then
  skip "没有 file 命令，验不了 sysroot"
else
  desc=$(file -b "$lib")
  case "$desc" in
    *ELF*aarch64*) pass "sysroot 装的是目标二进制 → 跟 host 无关，原样搬"
                   note "$desc" ;;
    *)             fail "sysroot 的 libc.so 不是 aarch64 ELF：$desc" ;;
  esac
fi

# --- 2c. 要重编多少 vs 原样搬多少
#     跟 host 无关的不止 sysroot：lib/clang/<ver>/ 那个 resource dir 里
#     全是各目标架构的 compiler-rt、编译器内建头文件和两个脚本，
#     一个 host 二进制都没有。它跟 sysroot 是同一类，也是原样搬。
if command -v du >/dev/null; then
  all_mb=$(du -sm "$PREBUILT" 2>/dev/null | cut -f1)
  sys_mb=$(du -sm "$PREBUILT/sysroot" 2>/dev/null | cut -f1)
  res_mb=0
  for rd in "$PREBUILT"/lib/clang/*/; do
    [ -d "$rd" ] || continue
    n=$(du -sm "$rd" 2>/dev/null | cut -f1)
    res_mb=$((res_mb + ${n:-0}))
  done
  if [ -n "$all_mb" ] && [ -n "$sys_mb" ]; then
    keep=$((sys_mb + res_mb))
    if [ "$((all_mb - keep))" -lt 0 ]; then
      fail "体量算出负数（共 $all_mb，其中「原样搬」$keep）—— 参照 host tag 挑错了"
      note "$PREBUILT 大概是个薄壳（sysroot / lib/clang 是软链，du 不跟随）"
      note "真工具链那份还在的话，重跑 tools/make-shim-toolchain.sh 让薄壳带上标记"
    else
      note "toolchains/llvm 共 $all_mb MB"
      note "  要重编   $((all_mb - keep)) MB"
      note "  原样搬   $keep MB = sysroot $sys_mb + resource dir $res_mb"
    fi
  fi
  # resource dir 里唯一可能藏 host 二进制的地方是 bin/
  hostbin=0
  # **这条的通过值恰好是 0**，所以「数出来是 0」得先排除「根本没数成」：
  # file 不在的话每个文件都不匹配，hostbin 停在 0，直接报 pass —— 假绿。
  # 数不成就走 skip（这个脚本的「没验成」档），不能塌进 pass。
  if ! command -v file >/dev/null; then
    skip "没有 file 命令，验不了 resource dir 里有没有 host 二进制"
  else
    for f in "$PREBUILT"/lib/clang/*/bin/*; do
      [ -f "$f" ] || continue
      case "$(file -b "$f" 2>/dev/null)" in *ELF*|*PE32*) hostbin=$((hostbin+1)) ;; esac
    done
    if [ "$hostbin" -eq 0 ]; then
      pass "resource dir 里没有 host 二进制 → 跟 sysroot 同类，原样搬"
    else
      fail "resource dir 的 bin/ 里有 $hostbin 个 host 二进制，不能整个原样搬"
    fi
  fi
fi

# ------------------------------------------------------------------ 2.1
head_ "2.1 写死 host tag 的地方"

files=$(grep -rl -E '(linux|darwin|windows)-x86_64' "$NDK/build" "$NDK/meta" 2>/dev/null | sort)
if [ -z "$files" ]; then
  fail "一个都没找到 —— NDK 结构可能变了，第二节的结论要重看"
else
  printf '%s\n' "$files" | while IFS= read -r f; do note "${f#"$NDK/"}"; done
  info "$(printf '%s\n' "$files" | grep -c .) 个文件写死了 host tag（数量随 NDK 版本变）"
fi

# ndk_bin_common.sh 是 ndk-build 走的路径。它不写死 host tag，而是按
# uname -m 判断——但 case 里没有 aarch64 分支，直接落到 *) 报错退出。
# 这是 aarch64 上第一个会挡住 ndk-build 的地方，也是最小的一处改动。
bincommon="$NDK/build/tools/ndk_bin_common.sh"
if [ -f "$bincommon" ]; then
  if grep -qE '^[[:space:]]*[^)]*aarch64[^)]*\)' "$bincommon"; then
    pass "ndk_bin_common.sh 认得 aarch64"
  else
    block "ndk_bin_common.sh 的 HOST_ARCH case 没有 aarch64 分支 → aarch64 上 ndk-build 直接退出"
    note "$(grep -n 'Unknown host CPU' "$bincommon" | head -1)"
  fi
fi

# CMake 那条路径：Linux 分支连 host CPU 都不判，一律 linux-x86_64。
# 两个文件都得看——android.toolchain.cmake 开头默认会 include legacy 那份
# 然后 return()，也就是说不显式传 -DANDROID_USE_LEGACY_TOOLCHAIN_FILE=OFF
# 的话，真正跑到的是 android-legacy.toolchain.cmake。只改一个等于没改。
for tc in "$NDK/build/cmake/android.toolchain.cmake" \
          "$NDK/build/cmake/android-legacy.toolchain.cmake"; do
  [ -f "$tc" ] || continue
  base=$(basename "$tc")
  if grep -qE 'ANDROID_HOST_TAG[[:space:]]+linux-(aarch64|arm64)' "$tc"; then
    pass "$base 认得 linux-aarch64"
  else
    block "$base 的 Linux 分支写死 linux-x86_64，不判 host CPU"
    note "$(grep -n 'ANDROID_HOST_TAG linux' "$tc" | head -1)"
  fi
done

if grep -q '_USE_LEGACY_TOOLCHAIN_FILE true' "$NDK/build/cmake/android.toolchain.cmake" 2>/dev/null; then
  note "默认走 legacy 那份——两个文件都要改。"
fi

# 第三条求 host tag 的路径：make_standalone_toolchain.py 只看 sys.platform，
# 不看 CPU。它不报错，直接返回 linux-x86_64，再拿这个 tag 去找目录，
# 报「Could not find toolchain」——比 ndk_bin_common.sh 那条安静，一样走不通。
mst="$NDK/build/tools/make_standalone_toolchain.py"
if [ -f "$mst" ]; then
  if grep -qE '"linux-(aarch64|arm64)"' "$mst"; then
    pass "make_standalone_toolchain.py 认得 linux-aarch64"
  else
    block "make_standalone_toolchain.py 只看 sys.platform，aarch64 上会返回 linux-x86_64"
    note "$(grep -n 'return \"linux-x86_64\"' "$mst" | head -1)"
  fi
fi

# 第四条路径：ndk-build 真正编东西时走的那条。
# init.mk 里 HOST_ARCH 是无条件的 x86/x86_64，拼出 HOST_TAG64 再喂给
# TOOLCHAIN_ROOT —— 决定用哪个 clang 的就是它，跟 ndk_bin_common.sh 无关。
#
# 上面 2.1 那个 grep 抓不到这里：那边找的是字面量 linux-x86_64，
# 而这里是 $(HOST_OS_BASE)-$(HOST_ARCH64) 拼出来的。所以单独查。
initmk="$NDK/build/core/init.mk"
if [ -f "$initmk" ]; then
  if grep -qE 'HOST_ARCH(64)?[[:space:]]*:?=[[:space:]]*aarch64' "$initmk"; then
    pass "init.mk 认得 aarch64（ndk-build 真正编东西走的那条）"
  else
    block "init.mk 的 HOST_ARCH 无条件设成 x86_64 → ndk-build 会去 exec x86_64 的 clang"
    note "$(grep -n 'HOST_ARCH64 := x86_64' "$initmk" | head -1)"
    note "症状是 clang: 1: Syntax error —— shell 把 ELF 当脚本读了，不是编译错误"
  fi
fi


# ---------------------------------------------------------------- 3
# 补丁只让 NDK「认得」linux-aarch64。认得之后，它会去这几个地方找东西，
# 而这几个地方现在是空的——那正是 M1 要产出的。
case "$(uname -s)/$(uname -m)" in
  Linux/aarch64|Linux/arm64) native_tag="linux-aarch64" ;;
  *)                         native_tag="" ;;
esac

if [ -n "$native_tag" ]; then
  head_ "3. $native_tag 底下还差什么（M1 的产出清单）"
  missing=0
  for d in "toolchains/llvm/prebuilt/$native_tag/bin/clang" \
           "toolchains/llvm/prebuilt/$native_tag/python3/bin/python3" \
           "prebuilt/$native_tag/bin/make"; do
    if [ -e "$NDK/$d" ]; then
      pass "$d"
    else
      note "缺   $d"
      missing=$((missing + 1))
    fi
  done
  if [ "$missing" -gt 0 ]; then
    info "$missing 项还没有。ndk-build 会退回去用系统的同名工具。"
    note "make 退回系统的能用（$(command -v make 2>/dev/null || echo '没装！')）。"
    if command -v python >/dev/null 2>&1; then
      note "python 退回系统的也能用（$(command -v python)）。"
    else
      note "python 退不掉：init.mk 最后兜底是裸的 \`python\`，而这台机器只有 python3。"
      note "这是**静默降级**——不报错，但 \$(shell \$(HOST_PYTHON) ...) 全返回空，"
      note "APP_PLATFORM 之类会悄悄取默认值。临时绕过："
      note "  NDK_HOST_PYTHON=\$(command -v python3) ndk-build ..."
    fi
  fi
fi
if [ "$blockers" -gt 0 ]; then
  head_ "小结"
  note "$blockers 处已知阻塞点 —— 上游现状，不是回归。修掉它们就是这个项目的活。"
fi

exit $rc
