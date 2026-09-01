#!/usr/bin/env bash
# 自己编一份 make_f2fs。
#
# 公共骨架在 tools/build-common.sh。**只多取一棵树**（external/f2fs-tools，2 MB）：
# libext2_uuid 和 libsparse 是 mke2fs 那轮已经产出的，libbase 在上游那棵树里。
# 所以这个脚本会把 cmake/mke2fs.cmake 和 cmake/make_f2fs.cmake **一起**装进上游的树
# （顺序要紧，mke2fs 在前）。**先跑 tools/build-aapt2.sh（至少 --fetch）。**
#
# 用法：
#   tools/build-make_f2fs.sh [--fetch|--build|--verify]
#   WORK=/path tools/build-make_f2fs.sh
#
# 环境变量：ALLOW_TAG_MISMATCH=1 / ALLOW_QEMU=1（见 tools/build-common.sh）

TOOL=make_f2fs
CMAKE_FILES=(mke2fs make_f2fs)   # 顺序要紧：make_f2fs 链 mke2fs 那边的 libext2_uuid
MIN_SIZE=300000
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build-common.sh" "$@"

if [ "$DO_FETCH" = 1 ]; then
  step "取 f2fs-tools 的源码"
  common_need_src
  common_need_protoc
  command -v git >/dev/null || die "没有 git"
  common_check_pin
  common_fetch_tree f2fs-tools external/f2fs-tools mkfs/f2fs_format_main.c
  # 这个脚本会一起装 cmake/mke2fs.cmake（要它的 libext2_uuid 和 libsparse），
  # 那份引用 e2fsprogs，所以这里也得取。已存在就跳过。
  common_fetch_tree e2fsprogs external/e2fsprogs misc/mke2fs.c
  ok "libsparse 的源码在上游那棵树里（core/libsparse），不用另取"
fi

if [ "$DO_BUILD" = 1 ]; then
  [ -f "$SRC/submodules/f2fs-tools/mkfs/f2fs_format_main.c" ] || die "源码不在，先跑 --fetch"
  [ -f "$SRC/submodules/e2fsprogs/misc/mke2fs.c" ] || die "e2fsprogs 不在，先跑本脚本的 --fetch"
  common_build
fi

if [ "$DO_VERIFY" = 1 ]; then
  common_verify_prelude
  command -v python3 >/dev/null || die "没有 python3，验不了超级块"
  command -v truncate >/dev/null || die "没有 truncate，造不出镜像文件"
  T="$WORK/verify-make_f2fs"; rm -rf "$T"; mkdir -p "$T"

  UUID=12345678-1234-5678-1234-567812345678
  # 三个开关一起才有确定性：-U 固定 UUID、-r 把 srand 归零、-T 固定时间戳。
  # f2fs 自己提供了这三个（`make_f2fs` 无参数时的用法里能看到），比 mke2fs 那边省事。
  mkfs() {
    rm -f "$1"; truncate -s 64M "$1"
    # -R 0:0 不能省：**root_uid/root_gid 的默认值是 getuid()/getgid()**
    # （lib/libf2fs.c:727，尽管 -R 的用法里写着「default: 0:0」），
    # 不显式给的话，谁跑的这条命令就写谁的 uid 进根 inode，比字节直接对不上。
    run_tool -q -f -r -T 1700000000 -U "$UUID" -l probe -R 0:0 "$1"
  }

  step "1/4  用法打得出来"
  u=$(run_tool 2>&1); rc=$?
  [ "$rc" != 0 ] || die "不给设备名它居然成功了"
  case "$u" in
    *"Usage: mkfs.f2fs"*) ok "用法打印出来了（退出码 $rc）" ;;
    *) die "打的东西不认识：$(echo "$u" | head -2)" ;;
  esac

  step "2/4  先确认这条测试会红：设备不存在必须失败"
  if run_tool -q -f "$T/does-not-exist/x.img" >/dev/null 2>&1; then
    die "对着一个不存在的路径，它居然成功了 —— 那这条测试测不出东西。
    先修测试，别信结果。"
  fi
  ok "不存在的设备被拒了（测试有效）"

  step "3/4  真干活：造一个 64 MB 的 f2fs，超级块得对"
  mkfs "$T/probe.img" >"$T/mkfs.log" 2>&1 || { sed 's/^/    /' "$T/mkfs.log" >&2; die "造镜像失败"; }
  sz=$(stat -c%s "$T/probe.img")
  [ "$sz" = 67108864 ] || die "镜像 $sz 字节，应该 67108864"
  python3 - "$T/probe.img" "$UUID" <<'SB' || die "超级块不对"
import struct, sys, pathlib, uuid
b = pathlib.Path(sys.argv[1]).read_bytes()
sb = b[1024:1024+640]                       # f2fs 超级块在 1024 偏移
magic = struct.unpack_from('<I', sb, 0)[0]
assert magic == 0xF2F52010, f'magic 不是 0xF2F52010，是 {magic:#x} —— 这不是 f2fs'
major, minor = struct.unpack_from('<HH', sb, 4)
assert (major, minor) == (1, 16), f'版本是 {major}.{minor}，应该 1.16'
got = str(uuid.UUID(bytes=sb[108:124]))
assert got == sys.argv[2], f'UUID 是 {got}，应该 {sys.argv[2]} —— -U 没生效？'
label = sb[124:124+512].decode('utf-16-le', 'ignore').split('\x00')[0]
assert label == 'probe', f'卷标是 {label!r}，应该 probe —— -l 没生效？'
SB
  ok "magic 0xF2F52010、版本 1.16、UUID 和卷标都是命令行给的那个"

  step "4/4  **跟官方 x86_64 的产物比对（归一化掉三处必然不同的字段）**"
  #
  # 直接比整个镜像也对不上，但**原因跟 mke2fs 那次不是一回事**，值得分清楚：
  #
  #   mke2fs 那边差的是 s_flags —— **架构**差异（x86 的 char 有符号，aarch64 无符号）。
  #   这边差的是 checkpoint_ver —— **libc** 差异。mkfs/f2fs_format.c:741 是
  #
  #       srand((c.fake_seed) ? 0 : time(NULL));
  #       cp->checkpoint_ver = cpu_to_le64(rand() | 0x1);
  #
  #   `-r` 让两边都 srand(0)，但**同一个种子在不同 libc 里 rand() 出来的数不一样**：
  #       官方（glibc）  0x6b8b4567
  #       我们（bionic） 0x7abd20a3
  #   我们编的是 bionic 二进制，所以这个值会跟着产物走 —— **真机上也是这个数**，
  #   跟 x86/ARM 无关，纯粹是 libc 的 rand() 实现不同。
  #
  # 还有**第三类**差异，跟架构和 libc 都无关，是**运行环境**：
  #
  #   sb->version / sb->init_version（超级块内 1668 和 1924，各 256 字节）
  #       f2fs_format.c:590-598 把**跑 mkfs 那台机器的内核版本串**写进超级块。
  #       容器里是 "6.18.44-fc-v22"，云上的 ARM 机器是 "6.17.0-1020-oracle"。
  #       换台机器就变，同一台升级内核也变 —— 必须归一化掉。
  #
  #   根 inode 的 uid/gid
  #       默认是 getuid()/getgid()，见上面 mkfs() 里那条注释。这个能用 -R 0:0
  #       固定，所以**用参数解决，不用归一化** —— 能固定的就固定，别都推给归一化。
  #
  # 这两条是**在真 ARM64 机器上才暴露的**：第一版黄金值把「容器的内核版本」和
  # 「root 的 uid」一起烤进去了，在别的机器上必然红。测试写得过死也是一种错，
  # 而且只有换台机器才照得出来。
  #
  # 归一化之后差异落在 3 个块（512 / 517 / 1023）的开头 8 字节（checkpoint_ver）
  # 和末尾 4 字节（块 CRC），加上块 0/1 的两个版本串。清零后两边**逐字节相同**。
  # 块号是写死的：这条测试造的镜像大小和参数是固定的，块布局也就固定。
  # 布局要是变了，归一化后的哈希会对不上，测试照样会红。
  python3 - "$T/probe.img" > "$T/norm.txt" <<'NORM2' || die "归一化失败"
import hashlib, struct, sys, pathlib
b = bytearray(pathlib.Path(sys.argv[1]).read_bytes())
ver = struct.unpack_from('<Q', b, 512 * 4096)[0]
kern = b[2692:2692 + 256].split(b'\x00')[0].decode('ascii', 'replace')
for blk in (0, 1):                          # 超级块 + 备份：内核版本串
    o = blk * 4096
    b[o + 2692:o + 2692 + 256] = b'\x00' * 256    # sb->version
    b[o + 2948:o + 2948 + 256] = b'\x00' * 256    # sb->init_version
for blk in (512, 517, 1023):                # checkpoint：ver + 块末 CRC
    o = blk * 4096
    b[o:o + 8] = b'\x00' * 8
    b[o + 4092:o + 4096] = b'\x00' * 4
print(hashlib.sha256(bytes(b)).hexdigest())
print(hex(ver))
print(kern)
NORM2
  got=$(sed -n 1p "$T/norm.txt"); ver=$(sed -n 2p "$T/norm.txt"); kern=$(sed -n 3p "$T/norm.txt")
  want=ec3d55f5fe71e17f3465033d7a602d8b44cd375ea24dd0e6c521621f68c6f004
  [ "$got" = "$want" ] || die "归一化之后还是跟官方对不上
    期望 $want
    实际 $got
    那就不止 checkpoint_ver 那几处不一样了 —— 用 cmp -l 跟官方的镜像比一比，
    看是又一处 libc/架构相关的字段，还是真编坏了。"
  ok "除 checkpoint_ver / 块 CRC / 内核版本串外，64 MB 镜像跟官方那份逐字节相同"
  note "超级块里记的内核版本是「$kern」—— 你这台机器的，归一化时清掉了"

  [ "$ver" = 0x7abd20a3 ] || die "checkpoint_ver 是 $ver，bionic 的 rand() 在种子 0 下
    应该给 0x7abd20a3。要么 -r 没生效（那产物就不确定了），要么 rand() 换了实现。"
  ok "checkpoint_ver = 0x7abd20a3（bionic 的 rand()；官方 glibc 那份是 0x6b8b4567）"

  common_verify_done "  用它造 f2fs 镜像：
    truncate -s 64M out.img && $BIN -f -l mylabel out.img"
fi
