#!/usr/bin/env bash
# 自己编一份 fastboot —— M3 里依赖最杂的一个。
#
# 公共骨架在 tools/build-common.sh。要另取**三棵树**（都很小，稀疏 checkout）：
#   system/extras          libext4_utils
#   external/avb           avb_headers
#   system/tools/mkbootimg bootimg_headers
# 另外四个上游 cmake/ 里没有的库由 cmake/fastboot.cmake 补出来。
# **先跑 tools/build-aapt2.sh（--fetch）。** 别的都自己取，不用先跑哪个工具的脚本。
#
# **验收的边界，先说清楚：** 没有一台处在 fastboot 模式的设备，能验的只有
# 版本、参数解析和错误路径。跟 tests/hello-* 需要真手机是同一类限制 ——
# 真正的验收得插一台机器，然后 `fastboot devices` 看得到它。
#
# 用法：
#   tools/build-fastboot.sh [--fetch|--build|--verify]
#   WORK=/path tools/build-fastboot.sh
#
# 环境变量：ALLOW_TAG_MISMATCH=1 / ALLOW_QEMU=1（见 tools/build-common.sh）

TOOL=fastboot
CMAKE_FILES=(mke2fs fastboot)   # 顺序要紧：fastboot 链 mke2fs 那边的 libsparse
MIN_SIZE=500000
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build-common.sh" "$@"

if [ "$DO_FETCH" = 1 ]; then
  step "取 fastboot 缺的三棵树"
  common_need_src
  common_need_protoc
  command -v git >/dev/null || die "没有 git"
  common_check_pin
  common_fetch_tree extras    system/extras       ext4_utils/ext4_utils.cpp  ext4_utils
  common_fetch_tree avb       external/avb        libavb/libavb.h            libavb
  common_fetch_tree mkbootimg system/tools/mkbootimg include/bootimg/bootimg.h include
  common_fetch_tree lz4       external/lz4        lib/lz4.c
  # 这个脚本会一起装 cmake/mke2fs.cmake（要它的 libsparse），那份引用 e2fsprogs，
  # 所以这里也得取。common_fetch_tree 已存在就跳过，重复取没有代价。
  common_fetch_tree e2fsprogs external/e2fsprogs  misc/mke2fs.c
  for f in core/fastboot/main.cpp core/fs_mgr/liblp/builder.cpp \
           core/diagnose_usb/diagnose_usb.cpp \
           core/fs_mgr/libstorage_literals/storage_literals/storage_literals.h; do
    [ -f "$SRC/submodules/$f" ] || die "$f 不在 —— 上游那棵树没取全？跑 tools/build-aapt2.sh --fetch"
  done
  ok "其余的（fastboot 本体 / liblp / libdiagnose_usb / libstorage_literals）都在上游那棵树里"
fi

if [ "$DO_BUILD" = 1 ]; then
  [ -f "$SRC/submodules/core/fastboot/main.cpp" ] || die "源码不在，先跑 --fetch"
  [ -f "$SRC/submodules/e2fsprogs/misc/mke2fs.c" ] \
    || die "e2fsprogs 不在（cmake/mke2fs.cmake 要它）—— 先跑本脚本的 --fetch"
  common_build
fi

if [ "$DO_VERIFY" = 1 ]; then
  common_verify_prelude
  T="$WORK/verify-fastboot"; rm -rf "$T"; mkdir -p "$T"

  step "1/3  版本号：前缀必须跟官方一致，后缀必然不同"
  # fastboot --version 打的是 "<PLATFORM_TOOLS_VERSION>-<build_number>"。
  #   前缀 35.0.2  来自 platform_tools_version.h（上游 patch.sh 拷进 soong 的那份），
  #                同一份源码编出来必须一样。
  #   后缀         是 **AOSP CI 的构建号**，Soong 从 BUILD_NUMBER 烤进去的：
  #                官方 fastboot version 35.0.2-12147458
  #                我们 fastboot version 35.0.2-          （空）
  #                我们没有那个号，**也不该编一个** —— 编上去等于冒充某一次官方构建。
  #                这是第五节第 6 条那张表里「运行环境」那一类：构建环境带来的差异。
  v=$(run_tool --version 2>&1 | head -1)
  case "$v" in
    "fastboot version 35.0.2-"*) ok "$v（官方那份后缀是 12147458，见上面注释）" ;;
    *) die "版本行的前缀都对不上
    期望 fastboot version 35.0.2-…
    实际 $v
    那就是 platform_tools_version.h 没拷进去或者版本变了。" ;;
  esac

  step "2/3  先确认这条测试会红：不认识的参数必须被拒"
  # **注意别用「不认识的子命令」当样本** —— `fastboot bogus-command` 会挂住等设备，
  # 官方那个也一样（实测跑满 2 分钟没退）。参数解析的错误路径是立刻返回的。
  if run_tool --bogus-flag-that-does-not-exist >/dev/null 2>&1; then
    die "喂它一个不存在的参数，它居然成功了 —— 那这条测试测不出东西。
    先修测试，别信结果。"
  fi
  ok "不认识的参数被拒了（测试有效）"

  step "3/3  devices：没有设备时也得干净地返回"
  # 这条验的是 USB 那半初始化得起来（usb_linux.cpp 会去扫 /dev/bus/usb）。
  out=$(run_tool devices 2>&1); rc=$?
  [ "$rc" = 0 ] || die "fastboot devices 退出码 $rc（没有设备时应该是 0）：$out"
  [ -z "$out" ] || note "列出了设备：$out"
  ok "devices 干净返回（退出码 0）"

  step "验收的边界"
  note "**上面三条验不到真正的功能。** fastboot 的活是跟一台处在 fastboot 模式的"
  note "设备说话，没有设备就只能验到「跑得起来、参数认得出、USB 扫描不炸」。"
  note "真正的验收：把设备重启到 bootloader，然后"
  note "    $BIN devices          # 应该看到它"
  note "    $BIN getvar product   # 应该拿到型号"
  note "跟 tests/hello-* 需要真手机是同一类限制，别把这三条当成通过了。"

  common_verify_done ""
fi
