#!/usr/bin/env bash
# 自己编一份 mke2fs —— M3 里源文件最多的一个（156 个）。
#
# 公共骨架在 tools/build-common.sh。**只多取一棵树**（external/e2fsprogs，43 MB）；
# libsparse 在 system/core 里，那棵本来就是上游 18 个子模块之一。
# **先跑 tools/build-aapt2.sh（至少 --fetch）。**
#
# 顺带产出七个静态库（libext2fs / libext2_blkid / libext2_uuid / libext2_e2p /
# libext2_com_err / libext2_quota / libext2_misc）加 libsparse —— make_f2fs 也要用
# 其中几个，所以下一个工具会便宜很多。
#
# **mke2fs 跑起来要一个 mke2fs.conf**（MKE2FS_CONFIG 指过去，或装到 /etc/mke2fs.conf），
# 没有会直接 abort。官方的 platform-tools 里带着一份；M4 做分发包时别忘了它。
#
# 用法：
#   tools/build-mke2fs.sh [--fetch|--build|--verify]
#   WORK=/path tools/build-mke2fs.sh
#
# 环境变量：ALLOW_TAG_MISMATCH=1 / ALLOW_QEMU=1（见 tools/build-common.sh）

TOOL=mke2fs
CMAKE_FILES=(mke2fs)
MIN_SIZE=500000
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build-common.sh" "$@"

if [ "$DO_FETCH" = 1 ]; then
  step "取 e2fsprogs 的源码"
  common_need_src
  common_need_protoc
  command -v git >/dev/null || die "没有 git"
  common_check_pin
  common_fetch_tree e2fsprogs external/e2fsprogs misc/mke2fs.c
  [ -f "$SRC/submodules/core/libsparse/sparse.cpp" ] \
    || die "找不到 libsparse 的源码（submodules/core/libsparse/sparse.cpp）——
    上游的 core 子模块没取全？跑 tools/build-aapt2.sh --fetch"
  ok "libsparse 的源码在上游那棵树里，不用另取"
fi

if [ "$DO_BUILD" = 1 ]; then
  [ -f "$SRC/submodules/e2fsprogs/misc/mke2fs.c" ] || die "源码不在，先跑 --fetch"
  common_build
fi

if [ "$DO_VERIFY" = 1 ]; then
  common_verify_prelude
  command -v python3 >/dev/null || die "没有 python3，验不了超级块"
  T="$WORK/verify-mke2fs"; rm -rf "$T"; mkdir -p "$T"

  # 自带一份 conf，不依赖 SDK 里那个文件 —— 下面第 4 步要拿官方产物比字节，
  # conf 变一个字节结果就变（实测：换掉 conf 哈希立刻不同）。
  cat > "$T/mke2fs.conf" <<'CONF'
[defaults]
    base_features = sparse_super,large_file,filetype,dir_index,ext_attr
    blocksize = 4096
    inode_size = 256
    inode_ratio = 16384

[fs_types]
    ext4 = {
        features = has_journal,extent,huge_file,dir_nlink,extra_isize,uninit_bg
        inode_size = 256
    }
    small = {
        blocksize = 1024
        inode_size = 128
        inode_ratio = 4096
    }
    floppy = {
        blocksize = 1024
        inode_size = 128
        inode_ratio = 8192
    }
CONF

  UUID=12345678-1234-5678-1234-567812345678
  # 三样东西一起才有确定性：固定 UUID、固定 hash_seed、假时间。
  # 少一样，产物里就带上真 UUID 或真时间戳，比字节这条就没法做了。
  mkfs() {  # $1 = 输出镜像
    rm -f "$1"
    MKE2FS_CONFIG="$T/mke2fs.conf" E2FSPROGS_FAKE_TIME=1700000000 \
      run_tool -q -t ext4 -b 4096 -U "$UUID" -E "hash_seed=$UUID" "$1" 16384
  }

  step "1/4  版本必须跟官方那份一致"
  ver=$(run_tool -V 2>&1 | head -1)
  case "$ver" in
    *"mke2fs 1.46.6"*) ok "$ver" ;;
    *) die "版本不是 1.46.6：$ver
    源码版本不一样，后面比字节就不作数了。" ;;
  esac

  step "2/4  先确认这条测试会红：没有可用的 conf 必须 abort"
  # 这是工具自己的真实错误路径，不是硬造的坏输入 —— 我第一次跑就撞上了。
  printf '[defaults]\n    blocksize = 4096\n' > "$T/bad.conf"   # 缺 [fs_types] 的 ext4
  if MKE2FS_CONFIG="$T/bad.conf" run_tool -q -t ext4 "$T/nope.img" 1024 >/dev/null 2>&1; then
    die "conf 里没定义 ext4，它居然还是造出来了 —— 那这条测试测不出东西。
    先修测试，别信结果。"
  fi
  ok "缺 ext4 定义的 conf 被拒了（测试有效）"

  step "3/4  真干活：造一个 64 MB 的 ext4，超级块得对"
  mkfs "$T/probe.img" 2>"$T/mkfs.err" || { sed 's/^/    /' "$T/mkfs.err" >&2; die "造镜像失败"; }
  sz=$(stat -c%s "$T/probe.img")
  [ "$sz" = 67108864 ] || die "镜像 $sz 字节，应该是 67108864（16384 x 4096）"
  # 「文件造出来了」不算验收：把超级块解开看看是不是真的 ext4
  python3 - "$T/probe.img" "$UUID" <<'PY' || die "超级块不对"
import struct, sys, pathlib, uuid
img = pathlib.Path(sys.argv[1]).read_bytes()
sb = img[1024:1024+264]                      # 超级块固定在 1024 偏移
magic = struct.unpack_from('<H', sb, 56)[0]
assert magic == 0xEF53, f'magic 不是 0xEF53，是 {magic:#x} —— 这不是 ext 文件系统'
blocks = struct.unpack_from('<I', sb, 4)[0]
assert blocks == 16384, f'块数是 {blocks}，应该 16384'
got = str(uuid.UUID(bytes=sb[104:120]))
assert got == sys.argv[2], f'UUID 是 {got}，应该 {sys.argv[2]} —— -U 没生效？'
PY
  ok "magic 0xEF53、16384 块、UUID 就是 -U 指定的那个"

  step "4/4  **跟官方 x86_64 的产物比对（归一化掉两个必然不同的字段）**"
  #
  # 直接比整个镜像的哈希是**对不上的**，而且对不上是应该的。实测下来，
  # 64 MB 的镜像里只有 **3 个字节**不一样，都在超级块里：
  #
  #   s_flags (0x160)           官方 1 = SIGNED_HASH，我们 2 = UNSIGNED_HASH
  #       lib/ext2fs/initialize.c:562 按**这台机器上 char 有没有符号**设置它 ——
  #       x86 的 char 有符号，aarch64 的无符号。ext4 有意把这一位记进超级块，
  #       因为目录哈希（dirhash）依赖 char 的符号性。
  #       **这是架构决定的，必然不同，不是我们编坏了。**
  #
  #   s_kbytes_written (0x178)  官方 4189，qemu 下我们 9
  #       「这个文件系统生命周期内写了多少 KB」的计数器，跟文件系统正确性无关。
  #       多半是 qemu 的 I/O 记账跟真机不同 —— **真机上跑这条才能定案**，
  #       下面会把实际值打出来。
  #
  # 把这两个字段清零之后，两边**逐字节完全相同**。所以这里比的是归一化之后的哈希。
  python3 - "$T/probe.img" > "$T/norm.txt" <<'NORM' || die "归一化失败"
import hashlib, struct, sys, pathlib
b = bytearray(pathlib.Path(sys.argv[1]).read_bytes())
sb = 1024
flags = struct.unpack_from('<I', b, sb + 0x160)[0]
kb    = struct.unpack_from('<Q', b, sb + 0x178)[0]
b[sb + 0x160:sb + 0x164] = b'\x00' * 4
b[sb + 0x178:sb + 0x180] = b'\x00' * 8
print(hashlib.sha256(bytes(b)).hexdigest())
print(flags)
print(kb)
NORM
  got=$(sed -n 1p "$T/norm.txt"); flags=$(sed -n 2p "$T/norm.txt"); kb=$(sed -n 3p "$T/norm.txt")
  want=30d77ab3e159a7a9c64be4be064cc867ab6a49b007b321c9ee70a57927cf9e28
  [ "$got" = "$want" ] || die "归一化之后还是跟官方对不上
    期望 $want
    实际 $got
    那就不止上面那两个字段不一样了 —— 值得查，别放过。"
  ok "除那两个字段外，64 MB 镜像跟官方那份逐字节相同"

  [ "$flags" = 2 ] || die "s_flags 是 $flags，aarch64 上应该是 2（UNSIGNED_HASH）——
    char 的符号性不对？那目录哈希会跟这台机器不一致。"
  ok "s_flags = 2（UNSIGNED_HASH）—— aarch64 该有的值，官方 x86 那份是 1"
  note "s_kbytes_written = $kb（官方 x86 那份是 4189）"
  note "  这个计数器跟文件系统正确性无关。qemu 下我们量到 9 —— **如果你是在真"
  note "  ARM64 机器上跑这条并且看到 4189，那就说明 9 是 qemu 的记账问题**；"
  note "  还是 9 的话，就是两边真的写法不同，值得单独查一次。"

  common_verify_done "  用它造 ext4 镜像（**MKE2FS_CONFIG 必须指到一份 conf**）：
    MKE2FS_CONFIG=/path/to/mke2fs.conf $BIN -t ext4 out.img 16384"
fi
