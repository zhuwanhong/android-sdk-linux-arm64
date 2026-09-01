#!/usr/bin/env bash
# 自己编一份 simpleperf 的 **host 那半** —— 官方 NDK 里
# `simpleperf/bin/linux/x86_64/` 那一份，是这个包里最后一个「只能我们编」的东西
# （设备端那半 `bin/android/<abi>/` 五个 ABI 官方包里都有，跟 host 架构无关）。
#
# 公共骨架在 tools/build-common.sh。**先跑 tools/build-aapt2.sh --fetch。**
#
# 要另取**七棵树**，都是上游那 18 个子模块里没有的：
#   external/OpenCSD                     libopencsd_decoder（ARM CoreSight ETM 解码）
#   external/rust/crates/rustc-demangle       librustc_demangle 本体
#   external/rust/crates/rustc-demangle-capi  librustc_demangle_static（C API，真正要链的）
#   system/libprocinfo                   libprocinfo
#   external/lzma                        liblzma（7-Zip SDK 那套，不是 XZ Utils）
#   external/libevent                    libevent
#   bionic（稀疏）                       libasync_safe（libunwindstack 的 LogAndroid.cpp 要）
# 五个在 googlesource 上都带 platform-tools-35.0.2 这个 tag，跟其余子模块 pin 一致。
# `libz` 不用取 —— NDK 的 sysroot 里就有 libz.a。
#
# 还要把 extras 那棵树的稀疏检出**加上 simpleperf**：那棵树是共用的，
# mke2fs/fastboot 只放出了 ext4_utils。用 `sparse-checkout add`（不是 set），
# 免得把别人要的目录关掉。
#
# ---------------------------------------------------------------------------
# **编出来的是静态 bionic 的 aarch64 二进制**，跟这个仓库其余 12 个工具一样
# （第三节验过：静态 bionic 二进制在 ARM64 Linux 上跑得起来）。官方那份是
# glibc 的，**这是一处已知的、有意的不同**，写进 PROVENANCE。
#
# **`libsimpleperf_report.so` 不在这个脚本的范围里。** 它是给 python 脚本用
# ctypes 加载的共享库，要进 CPython 进程 —— 一个进程里混不了 bionic 和 glibc，
# 所以它必须是 glibc 构建，那要给十几个 AOSP 库另配一套 host 构建。
# **那是另一条线，别在这里顺手做。**
#
# 用法：
#   tools/build-simpleperf.sh [--fetch|--build|--verify]
#   WORK=/path tools/build-simpleperf.sh
#
# 环境变量：ALLOW_TAG_MISMATCH=1 / ALLOW_QEMU=1（见 tools/build-common.sh）

TOOL=simpleperf
CMAKE_FILES=(simpleperf)
MIN_SIZE=1000000
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build-common.sh" "$@"

if [ "$DO_FETCH" = 1 ]; then
  step "取 simpleperf 缺的七棵树"
  common_need_src
  command -v git >/dev/null || die "没有 git"
  common_check_pin

  common_fetch_tree OpenCSD        external/OpenCSD \
      decoder/include/opencsd/ocsd_if_types.h
  common_fetch_tree rustc-demangle external/rust/crates/rustc-demangle \
      src/lib.rs
  common_fetch_tree libprocinfo    system/libprocinfo \
      process.cpp
  # **是 external/lzma 不是 external/xz** —— 后者在 googlesource 上根本不存在。
  # AOSP 的 liblzma 是 7-Zip SDK 那套（源码在 C/），不是 XZ Utils。
  # 探路的时候差点记错：第一版探测脚本把 git ls-remote 的 stderr 也收进了同一个
  # 变量，然后拿「非空」当「有」—— 仓库不存在的报错也算成了存在。
  # **失败和成功共用一个出口，这次是我自己的探测脚本犯的。**
  common_fetch_tree lzma           external/lzma \
      C/LzmaDec.c
  common_fetch_tree libevent       external/libevent \
      event.c
  # librustc_demangle_static **不在 rustc-demangle 那棵树里** —— 那棵只定义
  # librustc_demangle（rust_library）。带 C API 的静态库是另一个 crate。
  # 这个符号是硬需求：libunwindstack 的 Demangle.cpp:39 和 simpleperf 的
  # dso.cpp:292 都**无条件调用** rustc_demangle()，链接时必须有真实现。
  common_fetch_tree rustc-demangle-capi external/rust/crates/rustc-demangle-capi \
      src/lib.rs
  # 第七棵，第二轮才发现要：libunwindstack 的 LogAndroid.cpp include
  # <async_safe/log.h>，那是 bionic 平台内部的头，NDK sysroot 里没有。
  # 只要 libc 底下那几个目录，稀疏取。
  common_fetch_tree bionic bionic \
      libc/async_safe/include/async_safe/log.h \
      "libc/async_safe libc/include libc/private libc/platform libc/kernel"

  step "把 simpleperf 加进 extras 的稀疏检出"
  # extras 是共用的树（mke2fs / fastboot 要 ext4_utils），所以用 add 不用 set。
  ex="$SRC/submodules/extras"
  [ -d "$ex/.git" ] || die "submodules/extras 不在 —— 先跑 tools/build-mke2fs.sh --fetch
    或 tools/build-fastboot.sh --fetch（它们会取这棵树）"
  if [ -f "$ex/simpleperf/Android.bp" ]; then
    note "extras/simpleperf 已经在了"
  else
    git -C "$ex" sparse-checkout add simpleperf || die "sparse-checkout add simpleperf 失败"
  fi
  [ -f "$ex/simpleperf/main.cpp" ] || die "取下来了但 simpleperf/main.cpp 不在 —— 这个版本挪窝了？"
  ok "extras/simpleperf（$(ls "$ex/simpleperf" | wc -l) 个条目）"

  # -------------------------------------------------------------- 打我们的补丁
  # 跟 patches/ndk/、patches/aapt2/ 同一个路子：**改完用脚本验，别手改**。
  step "打 patches/simpleperf/ 里的补丁"
  EX="$SRC/submodules/extras"
  for pf in "$REPO"/patches/simpleperf/*.patch; do
    [ -f "$pf" ] || continue
    n=$(basename "$pf")
    if patch -d "$EX" -p1 -R --dry-run -s -f < "$pf" >/dev/null 2>&1; then
      note "$n 已经打过了"
    elif patch -d "$EX" -p1 --dry-run -s -f < "$pf" >/dev/null 2>&1; then
      patch -d "$EX" -p1 -s < "$pf" || die "打 $n 失败"
      ok "$n"
    else
      die "$n 打不上，也不像已经打过 —— 上游那棵树动过？
    自己看：patch -d $EX -p1 --dry-run < $pf"
    fi
  done
  # **打上了不等于有效**：确认那段代码真在里面。
  grep -q 'pair.second.empty()' "$EX/simpleperf/record_file_writer.cpp" \
    || die "补丁说打上了，但 record_file_writer.cpp 里找不到那个判断 —— 没真打上"
  ok "补丁都在（写 meta info 时会跳过空值）"

  step "核对 LLVM：simpleperf 直接 include 它的头"
  # libsimpleperf_readelf 这个名字是个坑：它不是 AOSP 的目标，
  # simpleperf 是直接 include llvm/Object/ELFObjectFile.h 之类。
  # 那棵树由 tools/build-llvm.sh 取。
  [ -d "$WORK/llvm/llvm-project/llvm/include/llvm/Object" ] \
    || warn "没看到 $WORK/llvm/llvm-project —— 先跑 tools/build-llvm.sh --fetch"

  for f in unwinding/libunwindstack/Elf.cpp libbase/file.cpp core/libcutils/android_reboot.cpp; do
    [ -f "$SRC/submodules/$f" ] || die "$f 不在 —— 上游那棵树没取全？跑 tools/build-aapt2.sh --fetch"
  done
  ok "其余依赖都在上游那棵树里"
fi

# ---------------------------------------------------------------------------
# 两个「不走 cmake 骨架」的预备件。放在这里而不是留在谁的终端历史里 ——
# 这个仓库的规矩是每件事都要能一条命令重跑。
SPDEPS="$WORK/out/simpleperf-deps"

sp_build_rust() {
  step "预备件一：librustc_demangle.a（Rust，交叉编到 aarch64-linux-android）"
  # rustc_demangle 是硬需求：libunwindstack/Demangle.cpp:39 和
  # simpleperf/dso.cpp:292 都**无条件调用**它。不塞空实现（取舍见 README 第三节）。
  local A="$SPDEPS/librustc_demangle.a"
  if [ -f "$A" ]; then note "已经有了：$A"; return 0; fi
  command -v cargo >/dev/null || die "没有 cargo。Ubuntu 24.04 的 apt 里就有 rustup，
    不用 curl | sh：
      sudo apt install -y rustup
      rustup toolchain install stable --profile minimal
      rustup target add aarch64-linux-android"
  _tl=$(rustc --print target-list 2>/dev/null)   # 不走管道，见 docs/LESSONS.md
  grep -qx aarch64-linux-android <<<"$_tl" \
    || die "这套 rust 不认 aarch64-linux-android 这个目标：rustup target add aarch64-linux-android"
  local C="$SRC/submodules/rustc-demangle-capi"
  [ -f "$C/Cargo.toml" ] || die "$C 不在，先跑 --fetch"
  mkdir -p "$SPDEPS"
  # **用旁边那棵 AOSP 树，不从 crates.io 拉**：capi 的 Cargo.toml 写的是
  # registry 依赖 rustc-demangle 0.1.16，patch 到本地的 0.1.23（同一棵 pin 的树）。
  # 不改源码树，改动只在命令行上。
  ( cd "$C" && cargo build --release --target aarch64-linux-android \
      --target-dir "$SPDEPS/cargo" \
      --config 'patch.crates-io.rustc-demangle.path="../rustc-demangle"' ) \
    || die "cargo 编不出来"
  cp "$SPDEPS/cargo/aarch64-linux-android/release/librustc_demangle.a" "$A" \
    || die "产物不在预期位置"
  # **不走管道。** `llvm-nm … | grep -q` 在 set -o pipefail 下会「命中反而报失败」：
  # grep -q 一命中就退出，llvm-nm 收到 SIGPIPE，pipefail 把整条管道判成失败。
  # docs/LESSONS.md 那张表里记过这一条，这里照样踩了一次。
  # 顺带把两种失败分开：nm 跑不起来 ≠ 符号不在。
  local NM="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/bin/llvm-nm"
  [ -x "$NM" ] || die "找不到 $NM"
  "$NM" --defined-only "$A" > "$SPDEPS/nm.txt" 2>"$SPDEPS/nm.err" \
    || die "llvm-nm 跑不起来：$(head -1 "$SPDEPS/nm.err")"
  grep -qw rustc_demangle "$SPDEPS/nm.txt" \
    || die "编出来了，nm 也读得动，但里面没有 rustc_demangle 这个符号"
  ok "$A（$(stat -c%s "$A") 字节，符号 rustc_demangle 在）"
}

sp_build_llvm() {
  step "预备件二：LLVM 的 Object/Support，交叉编到 aarch64-linux-android"
  # simpleperf 的 read_elf.cpp 直接 include llvm/Object/ELFObjectFile.h。
  # **tools/build-llvm.sh 编的是 host 工具链（glibc）**，那份静态库链不进
  # 静态 bionic 的目标二进制 —— 这是做到一半才发现的，记在 README 第三节第 4 条。
  local B="$WORK/llvm-android"
  if [ -f "$B/lib/libLLVMObject.a" ]; then note "已经有了：$B/lib/libLLVMObject.a"; return 0; fi
  local LP="$WORK/llvm/llvm-project"
  [ -f "$LP/llvm/CMakeLists.txt" ] || die "$LP 不在 —— 先跑 tools/build-llvm.sh --fetch"
  local TBLGEN="$WORK/llvm/build/bin/llvm-tblgen"
  [ -x "$TBLGEN" ] || die "交叉编要一份 **host** 的 llvm-tblgen，$TBLGEN 不在。
    先跑 tools/build-llvm.sh --build（它的构建树里就有）。"
  cmake -S "$LP/llvm" -B "$B" -GNinja \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-24 \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_NATIVE_TOOL_DIR="$WORK/llvm/build/bin" \
    -DLLVM_TARGETS_TO_BUILD=AArch64 \
    -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_UTILS=OFF -DLLVM_BUILD_TOOLS=OFF \
    || die "LLVM 交叉编配置失败"
  # ZSTD=OFF 是**待验的**，不是判断为无害就算了：NDK sysroot 里的 .a 用 ZSTD
  # 压了 debug 段（build-llvm.sh 开头记过这条）。等 simpleperf 能跑了，
  # 验收里要真读一个那样的文件，红了再把 zstd 开起来。
  ninja -C "$B" LLVMObject LLVMSupport LLVMBinaryFormat LLVMDemangle LLVMTargetParser \
    || die "LLVM 交叉编失败"
  ok "$B/lib/libLLVMObject.a（$(stat -c%s "$B/lib/libLLVMObject.a") 字节）"
}

if [ "$DO_BUILD" = 1 ]; then
  # **「还没做到」和「做了但失败」不能共用一个出口。** 这个工具是照 adb 那次
  # 分轮做的，第一轮 cmake/simpleperf.cmake 里只有四个依赖的目标，
  # simpleperf 本体还没定义 —— 那时候直接跑 ninja simpleperf 会报
  # 「unknown target」，看着像编挂了。这里先说清楚是哪一种。
  [ -f "$SRC/submodules/extras/simpleperf/main.cpp" ] || die "源码不在，先跑 --fetch"
  [ -f "$SRC/submodules/OpenCSD/decoder/include/opencsd/ocsd_if_types.h" ] \
    || die "OpenCSD 不在 —— 先跑本脚本的 --fetch"
  common_find_ndk
  sp_build_rust
  sp_build_llvm
  step "把路径写给 cmake"
  # 见 cmake/simpleperf.cmake 开头：不用 -D，免得动那组必须逐字一致的 flag。
  mkdir -p "$SRC/cmake"
  cat > "$SRC/cmake/simpleperf-paths.cmake" <<EOF
# 这个文件由 tools/build-simpleperf.sh 生成，别手改。
set(SIMPLEPERF_RUSTC_DEMANGLE "$SPDEPS/librustc_demangle.a")
set(SIMPLEPERF_LLVM_DIR "$WORK/llvm-android")
set(SIMPLEPERF_LLVM_SRC "$WORK/llvm/llvm-project/llvm")
EOF
  ok "$SRC/cmake/simpleperf-paths.cmake"

  common_build
fi

if [ "$DO_VERIFY" = 1 ]; then
  # common_verify_prelude 不找 NDK，而下面第 2 步要拿 sysroot 里的 libc.so 当输入。
  # 头一版漏了这句，$NDK 是空的，于是报的是「sysroot 里没找到 libc.so」——
  # **两种失败共用了一个出口**：真正的原因是变量没定义，不是文件不在。
  common_find_ndk
  common_verify_prelude
  T="$WORK/verify-simpleperf"; rm -rf "$T"; mkdir -p "$T"

  step "1/3  能不能起来，认不认自己的子命令"
  # 判据不是「--help 退出码 0」—— simpleperf 的 help 走的是子命令表，
  # 表没建起来它也可能打点东西就退。要看列出来的子命令。
  h=$(run_tool --help 2>&1)
  for sub in record report dump list stat; do
    case "$h" in *"$sub"*) ;; *) die "--help 里没有子命令 $sub：$(echo "$h" | head -3)" ;; esac
  done
  ok "五个核心子命令都在（record / report / dump / list / stat）"

  step "2/3  真录一段：perf_event 那条路通不通"
  # 判据不是「退出码 0」—— 事件类型不支持时它也退 0（上面那次实测过：
  # 报 "Event type 'cpu-clock' is not supported" 然后 rc=0）。看产物。
  #
  # 要 root：这台 perf_event_paranoid=4，普通用户开不了 perf 事件。
  # **开不了就明说没验**，不当过。
  if [ "$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo 9)" -le 1 ]; then
    SUDO=""
  elif sudo -n true 2>/dev/null; then
    SUDO="sudo -n"
    note "perf_event_paranoid=$(cat /proc/sys/kernel/perf_event_paranoid)，用 root 跑这一步"
  else
    SUDO=""
    warn "perf_event_paranoid=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null)，又没有 root ——"
    note "**这一步没验过**（不是失败，是没条件）。"
  fi
  if [ -n "$SUDO" ] || [ "$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo 9)" -le 1 ]; then
    rm -f "$T/perf.data"
    $SUDO "$BIN" record -o "$T/perf.data" -e cpu-clock --duration 1 sleep 1 >"$T/rec.log" 2>&1
    [ -s "$T/perf.data" ] || { sed 's/^/      /' "$T/rec.log" >&2; die "record 没写出 perf.data"; }
    n=$(grep -o 'Samples recorded: [0-9]*' "$T/rec.log" | head -1 | grep -o '[0-9]*$')
    [ -n "$n" ] && [ "$n" -gt 0 ] || { sed 's/^/      /' "$T/rec.log" >&2; die "录出来了但一个采样都没有"; }
    ok "record 跑通：$n 个采样，$(stat -c%s "$T/perf.data") 字节"

    # **录得出不等于读得回。** 这条曾经是红的：cmd_record.cpp 那段
    # #if defined(__ANDROID__) 会写 5 个空值（Linux 上取不到 ro.* 属性），
    # 而读的一侧把空值判成文件损坏 —— 录完的文件自己读不回。
    # patches/simpleperf/0001 修了写的那侧。这条测的就是它没回潮。
    [ -r "$T/perf.data" ] || $SUDO chown "$(id -u)" "$T/perf.data" 2>/dev/null || true
    "$BIN" report -i "$T/perf.data" > "$T/report.txt" 2>&1
    if grep -q 'invalid meta info' "$T/report.txt"; then
      sed 's/^/      /' "$T/report.txt" | head -3 >&2
      die "录出来的 perf.data 自己读不回 —— patches/simpleperf/0001 没打上？"
    fi
    # 判据不是「没报那句错」，是**真读出了采样数** —— 只判错误串的话，
    # report 因为别的原因什么都没输出时也会被判成通过。
    got=$(grep -oE '^Samples: [0-9]+' "$T/report.txt" | grep -oE '[0-9]+$')
    [ -n "$got" ] && [ "$got" -gt 0 ] \
      || { sed 's/^/      /' "$T/report.txt" | head -5 >&2; die "report 没读出采样数"; }
    ok "读得回来：report 读出 $got 个采样"
  fi

  step "3/3  ETM 解码器有没有真链进去"
  # OpenCSD 是新取的七棵树里最要紧的一棵（ARM 上最有用的就是 ETM）。
  # 判据得挑仔细：`list` 在没有 ETM 硬件的机器上本来就不会列出 cs-etm，
  # 拿它当判据会把「机器没这硬件」判成「没链进去」。改成两条都看：
  #   1. inject 子命令在（它就是 ETM 那条路的入口）
  #   2. 二进制里有 OpenCSD 的字符串 —— **直接 grep 文件，不走管道**
  #      （管道 + pipefail 会把命中判成失败，这个仓库和这个脚本都踩过）
  h2=$(run_tool --help 2>&1)
  case "$h2" in
    *inject*) ok "inject 子命令在（ETM 那条路的入口）" ;;
    *) die "没有 inject 子命令 —— ETM 那半没编进去" ;;
  esac
  if grep -qa 'OpenCSD\|ocsd_' "$BIN"; then
    ok "产物里有 OpenCSD 的痕迹，解码器链进去了"
  else
    die "产物里找不到 OpenCSD 的痕迹 —— libopencsd_decoder 没被链进来，
    那 ETM（ARM 上最有用的那部分）就是残的"
  fi

  common_verify_done
fi
