#!/usr/bin/env bash
# 自己编一份 zipalign。
#
# 公共骨架（找源码树、核对 tag、找 NDK、cmake 配置、编、strip、取产物）在
# tools/build-common.sh 里，几个工具共用。这里只留 zipalign 自己的部分：
# 要另取哪两棵树，和怎么验它。
#
# 跟 build-aapt2.sh **共用同一棵源码树和 build 目录** —— libbase / liblog /
# libutils / libziparchive 那些 aapt2 已经编过的静态库，ninja 直接拿来用。
# 所以：**先跑 tools/build-aapt2.sh（至少 --fetch）**。
#
# 上游那套 CMake 里没有 zipalign 目标（只编 aapt2），目标定义在
# cmake/zipalign.cmake，依赖照抄 AOSP 的 build/tools/zipalign/Android.bp。
# 上游的 18 个子模块里还少两棵树，这里另取，pin 在同一个 tag：
#
#     platform/build      zipalign 源码在 build/tools/zipalign/，不在 frameworks/base
#     external/zopfli     ZipFile.cpp 直接 #include "zopfli/deflate.h"
#
# 两棵加起来 2.5 MB，是稀疏 / 浅克隆。
#
# 用法：
#   tools/build-zipalign.sh              取源码 + 编 + 验
#   tools/build-zipalign.sh --fetch      只取那两棵树
#   tools/build-zipalign.sh --build      只编
#   tools/build-zipalign.sh --verify     只验已编出来的那个
#   WORK=/path tools/build-zipalign.sh   换工作目录（默认 <repo>/work，跟 aapt2 一致）
#
# 环境变量：
#   ALLOW_TAG_MISMATCH=1   上游子模块的 pin 跟 AOSP_TAG 对不上时也继续（默认拦下）
#   ALLOW_QEMU=1           非 aarch64 上用 qemu 跑那四条测试（**不算验收**）

TOOL=zipalign
CMAKE_FILES=(zipalign)
MIN_SIZE=200000
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build-common.sh" "$@"

# ---------------------------------------------------------------- 取源码
if [ "$DO_FETCH" = 1 ]; then
  step "取 zipalign 缺的那两棵树"
  common_need_src
  common_need_protoc          # 提前查。等 cmake 配置到一半才报，白等几分钟
  command -v git >/dev/null || die "没有 git"
  common_check_pin
  # platform/build 整棵几百 MB，只要 tools/zipalign 那一个目录（1.3 MB）
  common_fetch_tree build  build           tools/zipalign/ZipAlign.cpp  tools/zipalign
  common_fetch_tree zopfli external/zopfli src/zopfli/deflate.c
fi

# ---------------------------------------------------------------- 编
if [ "$DO_BUILD" = 1 ]; then
  [ -f "$SRC/submodules/build/tools/zipalign/ZipAlign.cpp" ] || die "zipalign 源码不在，先跑 --fetch"
  [ -f "$SRC/submodules/zopfli/src/zopfli/deflate.c" ]       || die "zopfli 源码不在，先跑 --fetch"
  common_build
fi

# ---------------------------------------------------------------- 验
if [ "$DO_VERIFY" = 1 ]; then
  common_verify_prelude

  # 真正的验收：让它干真活，而且**先确认这条测试会红**。
  # 第五节第 5 条：不会红的测试没有价值。所以样本 zip 是刻意造歪的，
  # 下面第 1 步 zipalign -c 必须失败；它要是「通过」了，说明样本没造歪，
  # 那这条测试根本没在测东西 —— 当场判失败。
  command -v python3 >/dev/null || die "没有 python3，造不出样本 zip"
  T="$WORK/verify-zipalign"; rm -rf "$T"; mkdir -p "$T"

  python3 - "$T" <<'PY' || die "造样本 zip 失败"
import sys, zipfile, pathlib
T = pathlib.Path(sys.argv[1])
# 第一个 entry 的数据偏移 = 30 + len(名字)。名字取 15 字节 -> 45，45 % 4 = 1，
# 也就是**一定**没对齐。不能指望"随便写一个就是歪的"。
name = "lib/libhello.so"          # 15 字节
assert (30 + len(name)) % 4 != 0, "名字长度选错了，这样造出来的是对齐的"
payload = bytes(range(256)) * 40  # 10 KB，别让它小到无所谓
with zipfile.ZipFile(T / "unaligned.zip", "w") as z:
    z.writestr(zipfile.ZipInfo(name), payload, compress_type=zipfile.ZIP_STORED)
    # 再塞一个压缩的 entry：-z 那步要靠它才真的走到 zopfli 的代码
    z.writestr(zipfile.ZipInfo("assets/text.txt"), b"hello zopfli\n" * 500,
               compress_type=zipfile.ZIP_DEFLATED)
(T / "payload.bin").write_bytes(payload)
PY

  step "1/4  先确认这条测试会红：歪的样本必须验不过"
  if run_tool -c 4 "$T/unaligned.zip" >/dev/null 2>&1; then
    die "样本 zip 居然通过了对齐检查 —— 那这条测试测不出任何东西。
    要么 python 造歪的那段失效了，要么 -c 没在检查。先修测试，别信结果。"
  fi
  ok "歪的样本被 -c 判失败了（测试有效）"

  step "2/4  zipalign -f 4 —— 真干活"
  run_tool -f 4 "$T/unaligned.zip" "$T/aligned.zip" || die "zipalign -f 4 失败"
  run_tool -c 4 "$T/aligned.zip" || die "自己对齐完的文件，自己的 -c 又说不对 —— 前后矛盾"
  ok "对齐后 -c 通过"

  step "3/4  内容不能被改坏"
  python3 - "$T" <<'PY' || die "对齐后内容对不上 —— 对齐成功但文件被改坏了"
import sys, zipfile, pathlib
T = pathlib.Path(sys.argv[1])
want = (T / "payload.bin").read_bytes()
with zipfile.ZipFile(T / "aligned.zip") as z:
    got = z.read("lib/libhello.so")
    txt = z.read("assets/text.txt")
assert got == want, f"lib/libhello.so 变了：{len(want)} -> {len(got)}"
assert txt == b"hello zopfli\n" * 500, "assets/text.txt 变了"
PY
  ok "两个 entry 的内容原样"

  step "4/4  -z：让 zopfli 真的被执行到"
  # 「链上了」不等于「跑过」。上一轮 libunwind 就是链上了但从没被触发。
  run_tool -z -f 4 "$T/unaligned.zip" "$T/zopfli.zip" || die "zipalign -z 失败（zopfli 那条路）"
  run_tool -c 4 "$T/zopfli.zip" || die "-z 出来的文件对不齐"
  python3 - "$T" <<'PY' || die "-z 之后内容对不上"
import sys, zipfile, pathlib
T = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(T / "zopfli.zip") as z:
    assert z.read("assets/text.txt") == b"hello zopfli\n" * 500
    info = z.getinfo("assets/text.txt")
    assert info.compress_size < info.file_size, "压缩后反而没变小，zopfli 那步可疑"
PY
  ok "zopfli 重压过，解出来一致"

  common_verify_done "  用它跑测试：
    AAPT2=$WORK/out/aapt2 ZIPALIGN=$BIN tests/hello-jvm/build.sh"
fi
