#!/usr/bin/env bash
# 自己编一份 etc1tool —— PNG <-> ETC1 压缩纹理（.pkm）互转。
#
# 公共骨架在 tools/build-common.sh。只差一棵树（platform/development，稀疏
# checkout 只要 tools/etc1tool）；libETC1 的源码在 frameworks/native 里，
# 那棵本来就是上游 18 个子模块之一。**先跑 tools/build-aapt2.sh（至少 --fetch）。**
#
# 用法：
#   tools/build-etc1tool.sh [--fetch|--build|--verify]
#   WORK=/path tools/build-etc1tool.sh
#
# 环境变量：ALLOW_TAG_MISMATCH=1 / ALLOW_QEMU=1（见 tools/build-common.sh）

TOOL=etc1tool
CMAKE_FILES=(etc1tool)
MIN_SIZE=200000
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build-common.sh" "$@"

if [ "$DO_FETCH" = 1 ]; then
  step "取 etc1tool 的源码"
  common_need_src
  common_need_protoc
  command -v git >/dev/null || die "没有 git"
  common_check_pin
  common_fetch_tree development development tools/etc1tool/etc1tool.cpp tools/etc1tool
  [ -f "$SRC/submodules/native/opengl/libs/ETC1/etc1.cpp" ] \
    || die "找不到 libETC1 的源码（submodules/native/opengl/libs/ETC1/etc1.cpp）——
    上游的 native 子模块没取全？跑 tools/build-aapt2.sh --fetch"
  ok "libETC1 的源码在上游那棵树里，不用另取"
fi

if [ "$DO_BUILD" = 1 ]; then
  [ -f "$SRC/submodules/development/tools/etc1tool/etc1tool.cpp" ] || die "源码不在，先跑 --fetch"
  common_build
fi

if [ "$DO_VERIFY" = 1 ]; then
  common_verify_prelude
  command -v python3 >/dev/null || die "没有 python3，造不出样本 PNG"
  T="$WORK/verify-etc1tool"; rm -rf "$T"; mkdir -p "$T"

  # 手写一个 16x16 的 PNG（不依赖 PIL）。**内容必须是确定的** —— 下面第 3 步要拿
  # 它的转换结果跟官方产物比哈希，输入变一个字节结果就对不上了。
  python3 - "$T" <<'PY' || die "造样本 PNG 失败"
import zlib, struct, sys, pathlib
T = pathlib.Path(sys.argv[1])
def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
W = H = 16
rows = b""
for y in range(H):
    rows += b"\x00" + bytes(v for x in range(W)
                            for v in ((x * 16) % 256, (y * 16) % 256, ((x + y) * 8) % 256))
png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(rows, 9))
       + chunk(b"IEND", b""))
(T / "probe.png").write_bytes(png)
assert len(png) == 558, f"PNG 大小变了（{len(png)}），下面的黄金哈希就不作数了"
PY
  ok "样本 PNG 558 字节（大小是断言过的）"

  step "1/3  先确认这条测试会红：不是 PNG 的文件必须被拒"
  echo "这不是 PNG" > "$T/notapng.png"
  [ -s "$T/notapng.png" ] || die "样本没造出来"
  # **坑：etc1tool 不用退出码报错。** 喂它一个非 PNG，它打一行
  #     <文件> is not a PNG file.
  # 然后 **exit 0**。官方 x86_64 那个也是这样（对照过），所以这是上游行为，
  # 不是我们编坏了 —— 这条测试因此查「那句话在不在」和「有没有真产出文件」，
  # 不查退出码。第一版写成 `if run_tool ...; then die` 的，红自检当场把它拦下了。
  msg=$(run_tool "$T/notapng.png" --encode -o "$T/nope.pkm" 2>&1)
  case "$msg" in
    *"is not a PNG file"*) ;;
    *) die "喂它一个纯文本，既没说不是 PNG，也没别的动静：「$msg」
    那这条测试测不出东西。先修测试，别信结果。" ;;
  esac
  [ ! -s "$T/nope.pkm" ] || die "它对一个纯文本产出了 .pkm —— 那它根本没在检查输入"
  ok "非 PNG 被认出来了，也没产出文件（测试有效）"

  step "2/3  真干活：PNG -> ETC1"
  run_tool "$T/probe.png" --encode -o "$T/probe.pkm" || die "--encode 失败"
  [ -s "$T/probe.pkm" ] || die "编码完了但 .pkm 是空的"

  step "3/3  **跟官方 x86_64 的产物逐字节一致**"
  # 下面这个哈希是拿 Google 官方 platform-tools r35.0.2（x86_64）跑同一个 PNG
  # 得到的。第四节「产物必须和官方 x86_64 版行为一致」—— 这条把那句话变成
  # 可检查的：ETC1 编码是有损压缩，实现稍有差别哈希就不一样。
  want=6c61320b662f2428290e22e9113ebe86913946f527167982ff8b128e9f26422d
  got=$(sha256sum "$T/probe.pkm" | cut -d' ' -f1)
  sz=$(stat -c%s "$T/probe.pkm")
  [ "$sz" = 144 ] || die "输出 $sz 字节，官方那份是 144"
  [ "$got" = "$want" ] || die "哈希跟官方对不上
    期望 $want
    实际 $got
    ETC1 是有损压缩，这说明编码结果真的不一样，值得查。"
  ok "144 字节，sha256 跟官方那份完全一致"

  common_verify_done "  用它转纹理：
    $BIN in.png --encode -o out.pkm
    $BIN in.pkm --decode -o out.png"
fi
