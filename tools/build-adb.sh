#!/usr/bin/env bash
# 自己编一份 adb。M3 的最后一块，也是这些工具里最大的一个。
#
# 公共骨架在 tools/build-common.sh。**先跑 tools/build-aapt2.sh（至少 --fetch）。**
#
# 跟别的工具比，adb 多出三件事：
#
#   1. **另取五棵树**：adb libusb mdnsresponder openscreen zstd（brotli 和 core
#      是上游子模块里就有的）。
#   2. **装三份 cmake**：fastboot.cmake 要在前面 —— libdiagnose_usb 和 liblz4
#      定义在那儿，adb 的 static_libs 里有它俩。所以这个脚本也得把 fastboot
#      那几棵树取下来（跟 build-make_f2fs.sh 要带上 mke2fs 是同一回事）。
#   3. **--build 之前先跑一个 Java 子构建**：tools/gen-deployagent.sh。
#      adb 的 generated_headers 有一项的输入是 java_binary 模块，详见那个脚本
#      开头。cmake 不管这件事，少了它会在 client/fastdeploy.cpp 上报
#      'deployagent.inc' file not found —— 一条清楚的错。
#
# 用法：
#   tools/build-adb.sh [--fetch|--build|--verify]
#
# 环境变量：ALLOW_TAG_MISMATCH=1 / ALLOW_QEMU=1（见 tools/build-common.sh）

TOOL=adb
CMAKE_FILES=(fastboot adb-deps adb)   # 顺序要紧：fastboot 提供 libdiagnose_usb / liblz4
MIN_SIZE=3000000
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build-common.sh" "$@"

if [ "$DO_FETCH" = 1 ]; then
  step "取 adb 那几棵树"
  common_need_src
  common_need_protoc
  command -v git >/dev/null || die "没有 git"
  common_check_pin
  common_fetch_tree adb           packages/modules/adb  adb.cpp
  common_fetch_tree libusb        external/libusb       libusb/core.c
  common_fetch_tree mdnsresponder external/mdnsresponder mDNSShared/dnssd_clientlib.c
  common_fetch_tree openscreen    external/openscreen   platform/api/udp_socket.cc
  common_fetch_tree zstd          external/zstd         lib/common/error_private.c
  # brotli 和 core 在上游子模块里就有；万一没有，下面这两条会取。
  common_fetch_tree brotli        external/brotli       c/dec/decode.c
  common_fetch_tree core          system/core           libcrypto_utils/android_pubkey.cpp
  # 这个脚本装 fastboot.cmake（要它的 libdiagnose_usb / liblz4），那份引用的树
  # 也得在，否则 cmake **配置阶段**就会报找不到源文件。
  common_fetch_tree extras        system/extras         ext4_utils/ext4_utils.cpp  ext4_utils
  common_fetch_tree avb           external/avb          libavb/libavb.h            libavb
  common_fetch_tree mkbootimg     system/tools/mkbootimg include/bootimg/bootimg.h  include
  common_fetch_tree lz4           external/lz4          lib/lz4.c
  common_fetch_tree e2fsprogs     external/e2fsprogs    misc/mke2fs.c

  # -------------------------------------------------------------- 打我们的补丁
  # 跟 patches/ndk/、patches/aapt2/、patches/simpleperf/ 同一个路子：
  # **改完用脚本验，别手改**。
  step "打 patches/adb/ 里的补丁"
  AD="$SRC/submodules/adb"
  for pf in "$REPO"/patches/adb/*.patch; do
    [ -f "$pf" ] || continue
    n=$(basename "$pf")
    if patch -d "$AD" -p1 -R --dry-run -s -f < "$pf" >/dev/null 2>&1; then
      note "$n 已经打过了"
    elif patch -d "$AD" -p1 --dry-run -s -f < "$pf" >/dev/null 2>&1; then
      patch -d "$AD" -p1 -s < "$pf" || die "打 $n 失败"
      ok "$n"
    else
      die "$n 打不上，也不像已经打过 —— 上游那棵树动过？
      自己看：patch -d $AD -p1 --dry-run < $pf"
    fi
  done
  # **打上了不等于有效**：确认那行真在里面。
  grep -q 'android_fdsan_set_error_level' "$AD/client/main.cpp" \
    || die "补丁说打上了，但 client/main.cpp 里找不到那行 —— 没真打上"
fi

if [ "$DO_BUILD" = 1 ]; then
  [ -f "$SRC/submodules/adb/adb.cpp" ] || die "adb 源码不在，先跑 --fetch"
  [ -f "$SRC/submodules/openscreen/platform/api/udp_socket.cc" ] || die "openscreen 不在，先跑 --fetch"

  # Java 子构建要在 cmake 之前 —— 它产出 client/fastdeploy.cpp 要 include 的
  # 两个 .inc。放到 build 目录底下（$SRC/build/adb-gen），cmake/adb.cmake 就在
  # ${CMAKE_BINARY_DIR}/adb-gen 找。
  step "先跑 Java 子构建（deployagent）"
  mkdir -p "$SRC/build"
  "$REPO/tools/gen-deployagent.sh" "$SRC/build/adb-gen" || die "gen-deployagent.sh 失败"
  for f in deployagent.inc deployagentscript.inc; do
    [ -s "$SRC/build/adb-gen/$f" ] || die "$f 没生成出来"
  done
  ok "两个 .inc 都在"

  common_build
fi

if [ "$DO_VERIFY" = 1 ]; then
  common_verify_prelude
  T="$WORK/verify-adb"; rm -rf "$T"; mkdir -p "$T"

  step "1/7  先确认这条测试会红：不认识的参数必须失败"
  # **用参数，不用子命令。** fastboot 那次记过：不认识的**子命令**会挂住等设备，
  # 实测跑满两分钟没退。adb 同理 —— `adb nosuchcmd` 会去连 server。
  # 参数解析这条路不碰网络，是安全的红自检。
  if run_tool --no-such-flag >/dev/null 2>&1; then
    die "不认识的参数它居然成功了 —— 那这条测试测不出东西"
  fi
  ok "不认识的参数被拒了（测试有效）"

  step "2/7  版本串"
  v=$(run_tool version 2>&1) || die "adb version 跑不起来"
  echo "$v" | sed 's/^/    /'
  case "$v" in
    *"Android Debug Bridge version 1.0.41"*) ;;
    *) die "版本头一行不对" ;;
  esac
  case "$v" in
    *"Version ${TOOLS_VERSION:-35.0.2}-"*) ;;
    *) die "Version 那行不是 35.0.2-" ;;
  esac
  ok "1.0.41 / 35.0.2"
  note "官方那份是 35.0.2-12147458，我们是 35.0.2-（空）。那个数字是 AOSP CI 的"
  note "构建号，**我们没有也不该编一个** —— 跟 fastboot 同一类，见第五节第 6 条"
  note "那张表里的「运行环境」。"

  step "3/7  fastdeploy 的 agent 真的嵌进去了"
  # 这一条专门盯着那个 Java 子构建。deployagent.jar 是个 zip，头四个字节是
  # PK\x03\x04；它被 xxd 成 kDeployAgent 数组编进只读段。**在二进制里找得到
  # 一段完整的 zip 头 + 里面 classes.dex 的名字**，就说明那一步真做了。
  # 光看「编过了」不够 —— 少了它 adb 照样能编、能跑，只是
  # `adb install --fastdeploy` 到设备上才炸。
  # **别写成 `strings -a "$BIN" | grep -q X`。** grep -q 一命中就退出，strings
  # 收到 SIGPIPE 挂掉，而这个脚本开头是 set -o pipefail —— 整条管道被判失败，
  # 于是一个**装得好好的** agent 被报成「没嵌进去」。第一版就是这么红的。
  # 直接 grep -a 二进制文件，不走管道，也少一个对 strings 的依赖。
  n_dex=$(grep -ac "classes.dex" "$BIN") || n_dex=0
  [ "$n_dex" -gt 0 ] || die "二进制里找不到 classes.dex —— deployagent.jar 没嵌进去？
    重跑 tools/gen-deployagent.sh 看看它有没有真的产出 deployagent.inc。"
  n_fd=$(grep -ac "com.android.fastdeploy" "$BIN") || n_fd=0
  [ "$n_fd" -gt 0 ] || die "找不到 com.android.fastdeploy —— 嵌进去的 jar 不是 agent"
  ok "kDeployAgent 里能找到 classes.dex（$n_dex 处）和 com.android.fastdeploy（$n_fd 处）"

  step "4/7  子命令列表跟官方一致"
  # adb 的能力清单就是 help 输出里的子命令。跟官方逐个比，少一个就说明
  # 某个 .cpp 没编进去或者某个 -D 没给。
  # help 走的是本地解析，不连 server。
  run_tool help 2>&1 | grep -oE "^ [a-z][a-z0-9-]+" | tr -d ' ' | sort -u > "$T/ours.txt"
  n=$(wc -l < "$T/ours.txt")
  [ "$n" -gt 25 ] || die "只解析出 $n 个子命令，太少 —— help 的格式变了还是编坏了"
  for c in devices shell install pull push logcat reboot root forward reverse; do
    grep -qx "$c" "$T/ours.txt" || die "子命令里没有 $c"
  done
  ok "$n 个子命令，常用的十个都在"

  step "5/7  连不上 server 时要给出清楚的错，而不是崩"
  # 没有设备也没有 server，adb devices 会自己起一个 server。这在验收机上
  # 是副作用，所以用 -H 指一个不存在的主机，强制它走「连不上」那条路。
  out=$(run_tool -H 127.0.0.1 -P 1 devices 2>&1); rc=$?
  [ "$rc" != 0 ] || die "连一个不存在的 server 居然成功了"
  case "$out" in
    *"cannot connect"*|*"failed to connect"*|*"Connection refused"*) ;;
    *) die "报的错看不懂：$(echo "$out" | head -2)" ;;
  esac
  ok "报的是「连不上」，退出码 $rc"

  # 注意：下面这段是**打给用户看的**，别在里面写反引号 —— 双引号里的反引号会被
  # 当成命令替换执行。第一版在这儿写了 `adb devices`，跑完末尾冒出一句
  # adb: command not found。
  step "6/7  **起一个真的 server**（非默认端口，不碰 5037）"
  # **这条是 2026-08-30 补的，补之前那个缺陷已经装进包了。**
  # 我们这份 adb 是静态 bionic，带着 bionic 独有的 fdsan；上游有一处 fd 所有权
  # 问题在 glibc 上永远看不见，在这儿就是**服务器一起就 abort**，本机实测 6/6
  # 必崩（详见 patches/adb/README.md）。而上面五步全是**本地解析**（版本串、
  # 参数、子命令表、二进制里的字符串），一次都没让它真起来过 —— 所以漏了。
  # **「能解析参数」不等于「能干活」。**
  #
  # 端口用非默认的：5037 上可能挂着 ssh -R 反向隧道，起个服务器会把它顶掉
  # （下一步注释里写着那个顺序）。
  aport=$(( 20000 + RANDOM % 20000 ))
  run_tool -L "tcp:$aport" kill-server >/dev/null 2>&1
  if ! run_tool -L "tcp:$aport" start-server >/dev/null 2>&1; then
    die "起不了 adb server（端口 $aport）。
    自己看：$BIN -L tcp:$aport server nodaemon
    崩在 fdsan 的话，说明 patches/adb/0001 没打上或者回潮了。"
  fi
  out=$(run_tool -P "$aport" devices 2>&1); rc=$?
  run_tool -P "$aport" kill-server >/dev/null 2>&1
  [ "$rc" = 0 ] || die "server 起来了但问不出设备列表（退出码 $rc）：$out"
  case "$out" in
    *"List of devices attached"*) ok "server 起得来、问得出设备列表、关得掉（端口 $aport）" ;;
    *) die "设备列表的输出不认识：$out" ;;
  esac

  step "7/7  跟真设备说一次话（要 ADB_DEVICE=1 才跑）"
  #
  # **前五步全是本地解析** —— 版本串、参数、子命令表、二进制里的字符串，
  # 一次协议往返都没有。adb 的活是跟设备说话，那才是它的验收。
  #
  # 默认不跑，要 ADB_DEVICE=1 显式打开：这一步会起一个 adb 服务器，
  # 在别人的机器上是个副作用（尤其云机器走 ssh -R 反向隧道时，本机多一个
  # 服务器会把隧道顶掉 —— tests/common.sh 的报错里写着那个顺序）。
  if [ "${ADB_DEVICE:-0}" != 1 ]; then
    note "跳过。有设备的话："
    note "    ADB_DEVICE=1 tools/build-adb.sh --verify"
    note "**这一条没验过** —— 前五步全是本地解析，跟设备说话是另一回事。"
  else
    st=$(run_tool get-state 2>&1) || die "看不到设备（get-state 说：$st）。
    云机器没 USB 的话要走 ssh -R 5037:localhost:5037，顺序见 tests/common.sh。"
    ok "get-state：$st"
    # 一次真正的往返：问设备要它的 ABI。这条走 shell 服务，是完整的
    # 连接-认证-开流-读结果，不是本地解析。
    abi=$(run_tool shell getprop ro.product.cpu.abi 2>&1 | tr -d '\r\n')
    case "$abi" in
      arm64-v8a|armeabi-v7a|x86_64|x86|riscv64) ok "设备 ABI：$abi（协议往返通了）" ;;
      *) die "getprop 拿回来的不像 ABI：「$abi」" ;;
    esac
  fi

  common_verify_done "  用它连设备：
    $BIN devices
    $BIN install app.apk

  **没验的**：跟真设备说话。跟 fastboot 一样，这台机器上验不了 —— 要
  一台开了 USB 调试的安卓机，adb devices 看得到它才算数。"
fi
