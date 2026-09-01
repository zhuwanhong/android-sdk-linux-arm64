#!/usr/bin/env bash
# 自己编一份 hprof-conv —— M3 里最小的一个：一个源文件，一个库都不链。
#
# 它把 Android 的 HPROF 1.0.3 转成标准 Java 的 1.0.2，好让 MAT / jhat 读得懂。
#
# 公共骨架在 tools/build-common.sh。要另取一棵树（platform/dalvik，稀疏 checkout
# 只要 tools/hprof-conv）。**先跑 tools/build-aapt2.sh（至少 --fetch）。**
#
# 用法：
#   tools/build-hprof-conv.sh [--fetch|--build|--verify]
#   WORK=/path tools/build-hprof-conv.sh
#
# 环境变量：ALLOW_TAG_MISMATCH=1 / ALLOW_QEMU=1（见 tools/build-common.sh）

TOOL=hprof-conv
CMAKE_FILES=(hprof-conv)
MIN_SIZE=100000
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build-common.sh" "$@"

if [ "$DO_FETCH" = 1 ]; then
  step "取 hprof-conv 的源码"
  common_need_src
  common_need_protoc
  command -v git >/dev/null || die "没有 git"
  common_check_pin
  common_fetch_tree dalvik dalvik tools/hprof-conv/HprofConv.c tools/hprof-conv
fi

if [ "$DO_BUILD" = 1 ]; then
  [ -f "$SRC/submodules/dalvik/tools/hprof-conv/HprofConv.c" ] || die "源码不在，先跑 --fetch"
  common_build
fi

if [ "$DO_VERIFY" = 1 ]; then
  common_verify_prelude
  command -v python3 >/dev/null || die "没有 python3，造不出样本"
  T="$WORK/verify-hprof-conv"; rm -rf "$T"; mkdir -p "$T"

  # 样本：一个最小的 1.0.3 文件，里面放一条 **Android 专有**的根记录
  # （HPROF_ROOT_INTERNED_STRING = 0x89）。转换应该做两件事：
  #   版本头 1.0.3 -> 1.0.2
  #   0x89 -> 0xff（HPROF_ROOT_UNKNOWN）
  python3 - "$T" <<'PY' || die "造样本失败"
import struct, sys, pathlib
T = pathlib.Path(sys.argv[1])
hdr  = b'JAVA PROFILE 1.0.3\x00' + struct.pack('>I', 4) + struct.pack('>Q', 0)
body = bytes([0x89]) + struct.pack('>I', 0xCAFEBABE)
rec  = bytes([0x1c]) + struct.pack('>I', 0) + struct.pack('>I', len(body)) + body
(T / 'in.hprof').write_bytes(hdr + rec)
# 已经是 1.0.2 的那份 —— 下面第 1 步要它被拒
(T / 'already.hprof').write_bytes(b'JAVA PROFILE 1.0.2\x00' + hdr[19:] + rec)
PY
  [ -s "$T/in.hprof" ] && [ -s "$T/already.hprof" ] || die "样本没造出来"

  step "1/3  先确认这条测试会红：已经是 1.0.2 的文件必须被拒"
  # 这是工具自己的一条真实错误路径（"HPROF file already in 1.0.2 format"），
  # 不是硬造的坏输入。
  if run_tool "$T/already.hprof" "$T/nope.hprof" >/dev/null 2>&1; then
    die "拿一个已经是 1.0.2 的文件喂它，居然转成功了 —— 那这条测试测不出东西。
    先修测试，别信结果。"
  fi
  ok "1.0.2 的输入被拒了（测试有效）"

  step "2/3  真干活：转一个 1.0.3"
  run_tool "$T/in.hprof" "$T/out.hprof" || die "转换失败"
  [ -s "$T/out.hprof" ] || die "转完了但输出是空的"

  step "3/3  **跟官方 x86_64 的产物逐字节一致**"
  # 下面这串是拿 Google 官方 platform-tools r35.0.2（x86_64）跑同一个输入得到的。
  # 第四节「不做什么」写着「产物必须和官方 x86_64 版行为一致」—— 这条把那句话
  # 变成可检查的：同样的输入，我们编的这个必须吐出同样的字节。
  python3 - "$T" <<'PY' || die "输出跟官方对不上"
import sys, pathlib
T = pathlib.Path(sys.argv[1])
got = T.joinpath('out.hprof').read_bytes()
assert got[:19] == b'JAVA PROFILE 1.0.2\x00', f'版本头没改：{got[:19]!r}'
tail = got[31:].hex()
want = '1c0000000000000005ffcafebabe'
assert tail == want, f'记录部分对不上\n  期望 {want}\n  实际 {tail}'
PY
  ok "版本头改了、0x89 改写成 0xff，字节跟官方那份一样"

  common_verify_done "  用它转 heap dump：
    $BIN android.hprof standard.hprof"
fi
