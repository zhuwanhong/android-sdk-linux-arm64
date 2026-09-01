#!/usr/bin/env bash
# 自己编一份 make_f2fs_casefold。
#
# 官方 platform-tools 里是**两个**二进制。这个是照 M4 的目标目录一个个数文件时
# 才发现漏掉的 —— 不是从 Android.bp 顺着读出来的，是从「要交付什么」倒着查出来的。
# 两条路都得走一遍。
#
# 源码和依赖跟 make_f2fs 完全一样，只多两个 -D（见 cmake/make_f2fs.cmake 末尾）。
# 目标定义就装在 cmake/make_f2fs.cmake 里，不另开文件 —— 同一份源码的两个变体，
# 分开写只会让两边慢慢长歪。
#
# 用法：
#   tools/build-make_f2fs_casefold.sh [--fetch|--build|--verify]
#
# 环境变量：ALLOW_TAG_MISMATCH=1 / ALLOW_QEMU=1（见 tools/build-common.sh）

TOOL=make_f2fs_casefold
CMAKE_FILES=(mke2fs make_f2fs)   # 顺序要紧：要 mke2fs 那边的 libext2_uuid
MIN_SIZE=300000
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build-common.sh" "$@"

if [ "$DO_FETCH" = 1 ]; then
  step "取 f2fs-tools 的源码"
  common_need_src
  common_need_protoc
  command -v git >/dev/null || die "没有 git"
  common_check_pin
  common_fetch_tree f2fs-tools external/f2fs-tools mkfs/f2fs_format_main.c
  common_fetch_tree e2fsprogs external/e2fsprogs misc/mke2fs.c
  ok "跟 build-make_f2fs.sh 取的是同两棵树，已存在会跳过"
fi

if [ "$DO_BUILD" = 1 ]; then
  [ -f "$SRC/submodules/f2fs-tools/mkfs/f2fs_format_main.c" ] || die "源码不在，先跑 --fetch"
  [ -f "$SRC/submodules/e2fsprogs/misc/mke2fs.c" ] || die "e2fsprogs 不在，先跑 --fetch"
  common_build
fi

if [ "$DO_VERIFY" = 1 ]; then
  common_verify_prelude
  command -v python3 >/dev/null || die "没有 python3，验不了超级块"
  command -v truncate >/dev/null || die "没有 truncate，造不出镜像文件"
  T="$WORK/verify-make_f2fs_casefold"; rm -rf "$T"; mkdir -p "$T"

  UUID=12345678-1234-5678-1234-567812345678
  # 参数跟 build-make_f2fs.sh 里那条**必须逐字一样**：两个黄金值是拿同一条命令
  # 分别喂给官方的两个二进制录的，参数一变两边都作废。
  # -R 0:0 不能省，理由见 build-make_f2fs.sh（root_uid 默认是 getuid()）。
  mkfs() {  # $1=镜像路径  $2...=用哪个二进制跑（空则用本工具）
    local img="$1"; shift
    rm -f "$img"; truncate -s 64M "$img"
    if [ $# -gt 0 ]; then
      run_bin "$1" -q -f -r -T 1700000000 -U "$UUID" -l probe -R 0:0 "$img"
    else
      run_tool -q -f -r -T 1700000000 -U "$UUID" -l probe -R 0:0 "$img"
    fi
  }

  # 超级块里这两个字段的偏移，是照 include/f2fs_fs.h 的 struct f2fs_super_block
  # 逐字段数出来的（sb 从镜像 1024 起，version 在 sb 内 1668，各 256 字节，
  # 之后 init_version 256，再之后就是 feature）。数出来对不对有验证：
  # plain 那份读出来必须是 0，casefold 必须是 0x1098。
  FEAT_OFF=$((1024 + 2180))     # __le32 feature
  ENC_OFF=$((1024 + 2758))      # __le16 s_encoding
  read_fields() {  # $1=镜像 -> 打印 "feature s_encoding"
    python3 - "$1" "$FEAT_OFF" "$ENC_OFF" <<'RF'
import struct, sys, pathlib
d = pathlib.Path(sys.argv[1]).read_bytes()
print(struct.unpack_from('<I', d, int(sys.argv[2]))[0],
      struct.unpack_from('<H', d, int(sys.argv[3]))[0])
RF
  }

  step "1/5  用法打得出来"
  u=$(run_tool 2>&1); rc=$?
  [ "$rc" != 0 ] || die "不给设备名它居然成功了"
  case "$u" in
    *"Usage: mkfs.f2fs"*) ok "用法打印出来了（退出码 $rc）" ;;
    *) die "打的东西不认识：$(echo "$u" | head -2)" ;;
  esac

  step "2/5  先确认这条测试会红：设备不存在必须失败"
  if run_tool -q -f "$T/does-not-exist/x.img" >/dev/null 2>&1; then
    die "对着一个不存在的路径，它居然成功了 —— 那这条测试测不出东西。
    先修测试，别信结果。"
  fi
  ok "不存在的设备被拒了（测试有效）"

  step "3/5  造镜像，超级块里那几位必须跟 make_f2fs 不一样"
  #
  # **这一步才是这个工具存在的理由。** 它跟 make_f2fs 共用全部源码，只多两个宏：
  #     CONF_CASEFOLD  s_encoding = 1(UTF8_12_1)，feature |= CASEFOLD 0x1000
  #     CONF_PROJID    feature |= QUOTA_INO 0x80 | PRJQUOTA 0x10 | EXTRA_ATTR 0x8
  # 宏没生效的话，编出来的东西跟 make_f2fs 一模一样，别的测试全会绿。
  mkfs "$T/probe.img" >"$T/mkfs.log" 2>&1 || { sed 's/^/    /' "$T/mkfs.log" >&2; die "造镜像失败"; }
  sz=$(stat -c%s "$T/probe.img")
  [ "$sz" = 67108864 ] || die "镜像 $sz 字节，应该 67108864"
  set -- $(read_fields "$T/probe.img")
  feat="$1"; enc="$2"
  [ "$feat" = 4248 ] || die "feature = $feat（0x$(printf %x "$feat")），应该 4248（0x1098）
    = CASEFOLD|QUOTA_INO|PRJQUOTA|EXTRA_ATTR。两个 -D 没生效？
    0 的话说明编出来的其实是一份 make_f2fs。"
  [ "$enc" = 1 ] || die "s_encoding = $enc，应该 1（F2FS_ENC_UTF8_12_1）"
  ok "feature = 0x1098，s_encoding = 1"

  # 手上要是有自己编的 make_f2fs，就当场用它反证一次：同样的参数，它必须给出 0。
  # 这是这条测试的变异测试，不用手工摘代码。
  PLAIN="$WORK/out/make_f2fs"
  if [ -x "$PLAIN" ]; then
    mkfs "$T/plain.img" "$PLAIN" >/dev/null 2>&1 || die "自己编的 make_f2fs 跑不起来"
    set -- $(read_fields "$T/plain.img")
    [ "$1" = 0 ] && [ "$2" = 0 ] \
      || die "自己编的 make_f2fs 造出来的镜像 feature=$1 s_encoding=$2，应该都是 0。
    两个变体串味了 —— 多半是那两个 -D 加到了 libf2fs_fmt 上（共用的静态库），
    而不是只加在可执行文件自己的源文件上。见 cmake/make_f2fs.cmake 末尾那段注释。"
    ok "拿自己编的 make_f2fs 反证：同样参数它给 0/0，两个变体没串味"
  else
    note "$PLAIN 不在，跳过「跟 make_f2fs 对照」那一步（tools/build-make_f2fs.sh 编出来再跑一次更稳）"
  fi

  step "4/5  **跟官方 x86_64 的产物比对（归一化掉的字段跟 make_f2fs 那条完全一样）**"
  #
  # 归一化的三处、为什么、以及「测试写得过死也是一种错」那段教训，都在
  # tools/build-make_f2fs.sh 第 4 步的注释里，不在这儿重抄一遍。
  # 这里只说**跟那条不同的地方**：
  #
  #   * 黄金值是另一个数 —— 两个变体的镜像实测差 19 个块（多出来的 quota inode
  #     和那几位 feature 让布局都变了），本来就该不一样。
  #   * 要归一化的块号**一样**：checkpoint_ver 在块 512/517/1023，实测过。
  #     casefold 改了布局但没挪 checkpoint 的位置。
  #   * 内核版本串在镜像里只出现在 2692/2948 和它们 +4096 处，扫过全镜像确认，
  #     没有第五处。
  python3 - "$T/probe.img" > "$T/norm.txt" <<'NORM' || die "归一化失败"
import hashlib, struct, sys, pathlib
b = bytearray(pathlib.Path(sys.argv[1]).read_bytes())
ver = struct.unpack_from('<Q', b, 512 * 4096)[0]
kern = b[2692:2692 + 256].split(b'\x00')[0].decode('ascii', 'replace')
for blk in (0, 1):
    o = blk * 4096
    b[o + 2692:o + 2692 + 256] = b'\x00' * 256
    b[o + 2948:o + 2948 + 256] = b'\x00' * 256
for blk in (512, 517, 1023):
    o = blk * 4096
    b[o:o + 8] = b'\x00' * 8
    b[o + 4092:o + 4096] = b'\x00' * 4
print(hashlib.sha256(bytes(b)).hexdigest())
print(hex(ver))
print(kern)
NORM
  got=$(sed -n 1p "$T/norm.txt"); ver=$(sed -n 2p "$T/norm.txt"); kern=$(sed -n 3p "$T/norm.txt")
  want=98beb9c8e16030aa0d48c5b7c15503b184122eb8c33447a0792188cc882d17c0
  [ "$got" = "$want" ] || die "归一化之后还是跟官方对不上
    期望 $want
    实际 $got
    照 make_f2fs 那次的办法查：逐块 cmp，看差在哪几个块，再对着
    include/f2fs_fs.h 认那是哪个字段、属于架构/libc/运行环境哪一类。
    别直接改黄金值。"
  ok "除 checkpoint_ver / 块 CRC / 内核版本串外，64 MB 镜像跟官方那份逐字节相同"
  note "超级块里记的内核版本是「$kern」—— 你这台机器的，归一化时清掉了"

  step "5/5  checkpoint_ver 是 bionic 的 rand()"
  [ "$ver" = 0x7abd20a3 ] || die "checkpoint_ver 是 $ver，bionic 的 rand() 在种子 0 下
    应该给 0x7abd20a3。要么 -r 没生效，要么 rand() 换了实现。"
  ok "checkpoint_ver = 0x7abd20a3（官方 glibc 那份是 0x6b8b4567）"

  common_verify_done "  用它造带 casefold 的 f2fs 镜像：
    truncate -s 64M out.img && $BIN -f -l mylabel out.img"
fi
