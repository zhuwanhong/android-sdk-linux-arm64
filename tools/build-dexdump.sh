#!/usr/bin/env bash
# 自己编一份 dexdump —— M2 四个里最后一个，也是最重的一个。
#
# 重在哪：另外三个最多多取一棵源码树，这个要**两棵**，还要自己定义四个库目标
# （libartbase / libdexfile / libartpalette / libtinyxml2），上游的 cmake/ 里一个都没有。
#
#     platform/art          dexdump 本体 + 三个 art 库（稀疏 checkout 四个目录，5.4 MB）
#     external/tinyxml2     libartbase 的 base/metrics/metrics_common.cc 直接用它
#
# tinyxml2 那条是查出来的：上游那 18 个子模块里没有它，而 metrics_common.cc 里
# tinyxml2::XMLElement 到处都是。**又一次「先确认源码在哪棵树里」。**
#
# 公共骨架在 tools/build-common.sh。同样复用 build-aapt2.sh 取来的源码树和 build
# 目录，**先跑 tools/build-aapt2.sh（至少 --fetch）**。
#
# 用法：
#   tools/build-dexdump.sh              取源码 + 编 + 验
#   tools/build-dexdump.sh --fetch      只取那两棵树
#   tools/build-dexdump.sh --build      只编
#   tools/build-dexdump.sh --verify     只验已编出来的那个
#   WORK=/path tools/build-dexdump.sh   换工作目录（默认 <repo>/work）
#
# 环境变量：
#   ALLOW_TAG_MISMATCH=1   上游子模块的 pin 跟 AOSP_TAG 对不上时也继续（默认拦下）
#   ALLOW_QEMU=1           非 aarch64 上用 qemu 跑那几条测试（**不算验收**）

TOOL=dexdump
CMAKE_FILES=(dexdump)
MIN_SIZE=500000
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build-common.sh" "$@"

if [ "$DO_FETCH" = 1 ]; then
  step "取 dexdump 缺的那两棵树"
  common_need_src
  common_need_protoc
  command -v git >/dev/null || die "没有 git"
  common_check_pin
  # platform/art 整棵很大，只要这四个目录
  # tools/ 是为了 generate_operator_out.py —— 那几个 operator<< 是生成的，
  # 少了它编译全过、链接才炸（见 cmake/dexdump.cmake 里那段）
  common_fetch_tree art art dexdump/dexdump.cc \
                    "dexdump libdexfile libartbase libartpalette tools"
  common_fetch_tree tinyxml2 external/tinyxml2 tinyxml2.cpp
fi

if [ "$DO_BUILD" = 1 ]; then
  [ -f "$SRC/submodules/art/dexdump/dexdump.cc" ] || die "art 源码不在，先跑 --fetch"
  [ -f "$SRC/submodules/tinyxml2/tinyxml2.cpp" ]  || die "tinyxml2 源码不在，先跑 --fetch"
  common_build
fi

if [ "$DO_VERIFY" = 1 ]; then
  common_verify_prelude

  T="$WORK/verify-dexdump"; rm -rf "$T"; mkdir -p "$T/src/com/example" "$T/out" "$T/classes"

  step "1/4  用法打得出来（没给文件时退出码 2）"
  u=$(run_tool 2>&1); rc=$?
  [ "$rc" = 2 ] || die "没给文件时退出码应该是 2，实际 $rc"
  case "$u" in
    *"display dex file header"*) ok "用法打印出来了，退出码 2" ;;
    *) die "打的东西不认识：$(echo "$u" | head -2)" ;;
  esac

  step "2/4  先确认这条测试会红：不是 dex 的文件必须被拒"
  # 不需要 SDK，所以这条自检在任何机器上都跑得到。
  printf 'dex\n035\x00 这不是一个 dex，只是开头几个字节像\n' > "$T/notadex.dex"
  # 先确认样本真的在。否则文件不存在时 dexdump 也会失败，这条测试就会
  # **因为错误的理由通过** —— 做变异测试时正好踩到过。
  [ -s "$T/notadex.dex" ] || die "假 dex 样本没造出来，下面那条测的就不是它了"
  if run_tool -f "$T/notadex.dex" >/dev/null 2>&1; then
    die "拿一个假 dex 喂它，居然成功了 —— 那这条测试测不出任何东西。
    （注意样本开头是故意写成 'dex\\n035' 的，就是要试它有没有真在校验。）
    先修测试，别信结果。"
  fi
  ok "假 dex 被拒了（测试有效）"

  # 后面两条要一个真 .dex。用 javac + d8 现造 —— d8 是 shell 脚本 + jar，
  # 跟 CPU 架构无关（第 1.2 节），ARM64 上原样能跑。
  BT=""
  for d in "${ANDROID_HOME:-}"/build-tools/*/; do BT="${d%/}"; done
  AJ=""
  for j in "${ANDROID_HOME:-}"/platforms/*/android.jar; do [ -f "$j" ] && AJ="$j"; done
  if [ -z "$BT" ] || [ ! -x "$BT/d8" ] || [ -z "$AJ" ] || ! command -v javac >/dev/null; then
    warn "缺 d8 / android.jar / javac（设一下 ANDROID_HOME），3/4 和 4/4 跳过 ——
    **那两条才是真干活的部分**，只验到「跑得起来、认得出坏输入」。"
    common_verify_done ""
    exit 0
  fi

  cat > "$T/src/com/example/Probe.java" <<'JAVA'
package com.example;

public class Probe {
    public static int addTwo(int a, int b) { return a + b; }
    public String greet(String who) { return "hello " + who; }
}
JAVA

  step "3/4  真干活：读一个真的 .dex"
  javac -nowarn -cp "$AJ" -d "$T/classes" "$T/src/com/example/Probe.java" > "$T/javac.log" 2>&1 \
    || { sed 's/^/    /' "$T/javac.log" >&2; die "javac 编不过样例（跟 dexdump 无关，是环境问题）"; }
  "$BT/d8" --output "$T/out" --lib "$AJ" "$T/classes/com/example/Probe.class" > "$T/d8.log" 2>&1 \
    || { sed 's/^/    /' "$T/d8.log" >&2; die "d8 转 dex 失败（跟 dexdump 无关，是环境问题）"; }
  DEX="$T/out/classes.dex"
  [ -f "$DEX" ] || die "d8 没报错但 $DEX 不在"

  run_tool -f "$DEX" > "$T/out/dump.txt" 2>"$T/out/dump.err" \
    || { sed 's/^/    /' "$T/out/dump.err" >&2; die "dexdump -f 读不了 d8 刚生成的 dex"; }
  # 「跑完没报错」不算验收（第五节第 2 条）：要它真把类和方法读出来
  for pat in 'Lcom/example/Probe;' 'addTwo' 'greet' 'DEX version'; do
    grep -qF "$pat" "$T/out/dump.txt" \
      || die "dump 出来的东西里没有「$pat」—— 它没真读懂这个 dex
    看一眼：$T/out/dump.txt"
  done
  ok "类名 / 两个方法名 / DEX 版本都读出来了（$(wc -l < "$T/out/dump.txt") 行）"

  step "4/4  校验和：好的必须过，改坏一个字节必须不过"
  run_tool -c "$DEX" >/dev/null 2>&1 || die "-c 说一个刚生成的 dex 校验和不对"
  # 把文件中段一个字节改掉。checksum 覆盖头 12 字节之后的全部内容，
  # 所以中间随便动一处就该被 -c 抓到。**这是这条测试会红的证据。**
  python3 - "$DEX" "$T/out/broken.dex" <<'PY' || die "造坏样本失败"
import sys, pathlib
b = bytearray(pathlib.Path(sys.argv[1]).read_bytes())
i = len(b) // 2
b[i] ^= 0xFF
pathlib.Path(sys.argv[2]).write_bytes(bytes(b))
PY
  if run_tool -c "$T/out/broken.dex" >/dev/null 2>&1; then
    die "改坏了一个字节，-c 居然还说校验和没问题 —— 它根本没在校验"
  fi
  ok "好的过、坏的不过"

  common_verify_done "  用它读 dex：
    $BIN -f classes.dex        # 头信息 + 类和方法
    $BIN -d classes.dex        # 反汇编"
fi
