#!/usr/bin/env bash
# 真机上验 lldb 调试：host lldb --(gdb-remote 隔着 adb)--> 设备上的 lldb-server。
#
# 这条是 docs/LESSONS.md「没验的」表里最后一行。link-system-tools.sh 已经在本机走过
# **环回**（同样的两个二进制、同样的协议），缺的只有「adb 传输」和「真设备」两环，
# 这个脚本补的就是这两环。判据跟环回那步**一模一样**，好对照：
#   1. 停得下来（协议通了，读得到寄存器）
#   2. 能继续到**正常退出**（不是连上就断）
# 只判第一条会把「连上了但立刻崩」判成通过。
#
# 用法：
#   tools/verify-lldb-device.sh
#   ADB=/path/to/adb ANDROID_HOME=/path/to/sdk tools/verify-lldb-device.sh
#   LLDB_PORT=5039 tools/verify-lldb-device.sh          # 换调试端口
#   ANDROID_SERIAL=<序列号> ...     多台设备时指定
#
# 退出码：0=验过了  1=真的失败  2=没条件验（没设备/缺件），**跟失败区分开**
set -uo pipefail

die()  { printf '\n  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }
skip() { printf '\n  \033[33m—\033[0m %s\n' "$1" >&2; exit 2; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/opt/android-sdk}}"

# 「文件在」不等于「能跑」——第五节第 2 条。
runs() { "$1" --version >/dev/null 2>&1 || "$1" version >/dev/null 2>&1; [ $? -lt 126 ]; }

step "找家伙什"
ADB="${ADB:-}"
[ -n "$ADB" ] || { for c in "$SDK/platform-tools/adb" "$(command -v adb 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && { ADB="$c"; break; }; done; }
[ -n "$ADB" ] && runs "$ADB" || skip "没有能跑的 adb（ADB=… 指过来）"
note "adb        $ADB"

NDK="${ANDROID_NDK_HOME:-}"
[ -n "$NDK" ] || { for d in "$SDK"/ndk/*/; do NDK="${d%/}"; done; }
[ -n "$NDK" ] && [ -d "$NDK" ] || skip "找不到 NDK"
TC="$NDK/toolchains/llvm/prebuilt/linux-aarch64"
SRV=$(ls "$TC"/lib/clang/*/lib/linux/aarch64/lldb-server 2>/dev/null | head -1)
[ -n "$SRV" ] || skip "NDK 里没有 aarch64 的 lldb-server"
note "lldb-server ${SRV#$NDK/}"

LL="$TC/bin/lldb"
[ -x "$LL" ] || LL=$(command -v lldb 2>/dev/null)
[ -n "$LL" ] && runs "$LL" || skip "没有能跑的 host lldb（跑 tools/link-system-tools.sh 把系统那份接进来）"
note "host lldb  $LL（$("$LL" --version 2>&1 | head -1)）"

# 靶子用我们自己编的 aapt2：**它是 Android 目标二进制**（静态 bionic），
# 设备上跑得动，而且 `version` 一跑就退、退出码 0，正好当「跑到正常退出」的判据。
# 环回那步用的也是它，两边可比。
TGT=""
for c in "$SDK"/build-tools/*/aapt2; do [ -x "$c" ] && runs "$c" && { TGT="$c"; break; }; done
[ -n "$TGT" ] || skip "找不到能跑的 aapt2 当靶子"
note "靶子       $TGT"

step "设备"
dev=$(timeout 30 "$ADB" devices | awk 'NR>1 && $2=="device" {print $1}')
n=$(printf '%s\n' "$dev" | grep -c . || true)
[ "$n" -ge 1 ] || skip "adb 看不到设备 —— **这条就是没条件验**，不是失败。
    云机器走 ssh 反向隧道（两端都写死 IPv4，localhost 可能解析成 ::1）：
      本机：adb kill-server
      有设备那台：adb start-server && adb devices
      有设备那台：ssh -R 127.0.0.1:5037:127.0.0.1:5037 <用户>@<这台>"
[ "$n" = 1 ] || [ -n "${ANDROID_SERIAL:-}" ] || skip "看到 $n 台设备，用 ANDROID_SERIAL=<序列号> 指一台"
note "序列号     $(printf '%s' "$dev" | head -1)  $(timeout 20 "$ADB" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
note "Android    $(timeout 20 "$ADB" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')（SDK $(timeout 20 "$ADB" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')）$(timeout 20 "$ADB" shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')"

cl=""; srv_log=""      # cleanup 里会用到，set -u 下必须先有值
D=/data/local/tmp/asdk-lldb-verify
# **端口是固定的，不随机。** 原因见下面那段「adb forward 开在哪台机器上」——
# 隔着 ssh 隧道用时，这个端口得预先 -R 过来，随机端口没法预先隧道。
port="${LLDB_PORT:-5039}"
cleanup() {
  [ -n "${srv_pid:-}" ] && { kill "$srv_pid" 2>/dev/null; wait "$srv_pid" 2>/dev/null; }
  timeout 20 "$ADB" forward --remove "tcp:$port" >/dev/null 2>&1
  # 杀本机的 adb shell **不会**杀掉设备上那个 lldb-server（实测手动试完留了 5 个僵着）。
  # 两个坑：① 进程的 argv[0] 是 ./lldb-server（相对路径），拿全路径 pkill -f 匹配不上；
  # ② 设备上 pkill -f 一样会自匹配。所以取 PID 再杀，并且**只杀 ARGS 里带我们这个
  # 目录的**（靶子是用绝对路径传的，认得出来），不误伤别人的 lldb-server。
  local pids
  pids=$(timeout 20 "$ADB" shell "ps -A -o PID,ARGS 2>/dev/null" 2>/dev/null | tr -d '\r' \
         | awk -v d="$D" '$0 ~ d && /lldb-server/ {print $1}' | tr '\n' ' ')
  [ -n "$pids" ] && timeout 20 "$ADB" shell "kill $pids" >/dev/null 2>&1
  timeout 30 "$ADB" shell "rm -rf $D" >/dev/null 2>&1
  rm -f "$cl" "$srv_log" 2>/dev/null
}
trap cleanup EXIT

step "推到设备上"
timeout 60 "$ADB" shell "rm -rf $D && mkdir -p $D" >/dev/null 2>&1 || die "在设备上建不了 $D"
timeout 300 "$ADB" push "$SRV" "$D/lldb-server" >/dev/null 2>&1 || die "推 lldb-server 失败"
timeout 300 "$ADB" push "$TGT" "$D/aapt2"       >/dev/null 2>&1 || die "推靶子失败"
timeout 60 "$ADB" shell "chmod 755 $D/lldb-server $D/aapt2" || die "chmod 失败"
# **先证明推上去的东西在设备上真能跑**，否则后面失败会分不清是「传输坏了」
# 还是「调试没通」。
out=$(timeout 60 "$ADB" shell "$D/aapt2 version" 2>&1 | tr -d '\r')
case "$out" in *"Android Asset Packaging Tool"*) ok "靶子在设备上跑得起来：$out" ;;
  *) die "靶子在设备上跑不起来：$out" ;; esac

step "转发端口（先做，且先探一次）"
# ---------------------------------------------------------------------------
# **adb forward 的监听口开在「跑 adb 服务器的那台机器」上，不一定是这台。**
# 直连 USB 时两者是同一台，没人会注意。可云机器走 ssh 反向隧道时：
#     这台的 adb 客户端 --(ssh -R 5037)--> 笔记本的 adb 服务器 --> 设备
# `adb forward` 于是在**笔记本**上开口，这台的 lldb 连过去只会 Connection refused
# （实测：adb forward --list 里那条在，本机 ss 里却没有那个口）。
#
# **这一探必须在起 lldb-server 之前做。** 它一旦起来，只接受**一个**客户端连接；
# 探测连上又立刻关闭，它就当客户端走了、自己退出，真正的 lldb 再连拿到的是
#     error: Connection shut down by remote side while waiting for reply to
#            initial handshake packet
# —— 这是实测撞出来的，探测顺序反了就会自己把自己废掉。
# 此刻设备那侧还没监听，连上的只是本地这一段（adb 或 ssh 接受连接），
# 这正好够判「口在不在本机」，而这就是要判的事。
timeout 20 "$ADB" forward --remove "tcp:$port" >/dev/null 2>&1
timeout 30 "$ADB" forward "tcp:$port" "tcp:$port" >/dev/null || die "adb forward 失败"
if ! timeout 10 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null; then
  skip "adb forward 建好了，但**这台机器上没人听 tcp:$port** —— 说明 adb 服务器不在本机
    （典型是走 ssh -R 5037 连的远端设备），forward 的口开在了那台上。

    把调试端口也反向转过来，在**有设备那台**上再开一条（不必断开现有会话）：
      ssh -N -R 127.0.0.1:$port:127.0.0.1:$port <用户>@<这台>
    然后重跑本脚本。"
fi
ok "adb forward tcp:$port -> 设备 tcp:$port（本机这个口有人听）"

step "在设备上起 lldb-server"
# 显式写 127.0.0.1，别写 :$port —— 这台实测两种写法都绑到 IPv4 回环，但别赌。
# **别把它的输出丢进 /dev/null。** 头一版丢了，结果「没起来」时屏幕上只有我的
# 断言，没有它的说法，查了两轮才定位。
srv_log=$(mktemp)
timeout 600 "$ADB" shell "cd $D && ./lldb-server gdbserver 127.0.0.1:$port -- $D/aapt2 version" >"$srv_log" 2>&1 &
srv_pid=$!
# **就绪判据看设备的 /proc/net/tcp，不看本地端口。**
# 头一版写的是「连一下本地 $port，连上就算就绪」—— 假绿：adb forward 一建好，
# 那个口就接受连接了，设备那侧有没有监听它不管。跟 ssh -R 那个坑同一类。
hex=$(printf '%04X' "$port")
ready=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  # **别写成 `... | grep -q`。** set -o pipefail 下 grep -q 一命中就退出，
  # 上游 cat/tr 收到 SIGPIPE，管道整体退出码非 0 —— 「找到了」会被判成「没找到」，
  # 循环白转。docs/LESSONS.md 里 llvm-nm 那条记的就是这个，我又踩了一次。
  nettcp=$(timeout 20 "$ADB" shell "cat /proc/net/tcp /proc/net/tcp6 2>/dev/null" 2>/dev/null | tr -d '\r')
  case "$nettcp" in *":$hex "*) ready=1; break ;; esac
  timeout 3 "$ADB" shell true >/dev/null 2>&1   # 当 sleep 用，顺带确认设备还在
done
if [ "$ready" != 1 ]; then
  printf '\n' >&2; sed 's/^/      /' "$srv_log" 2>/dev/null | tail -8 >&2
  die "设备上的 lldb-server 没起来（/proc/net/tcp 里等不到 :$port，上面是它的输出）"
fi
ok "设备上 lldb-server 在 127.0.0.1:$port 监听了"

step "连上去调"
cl=$(mktemp)
timeout 120 "$LL" -b -o "gdb-remote 127.0.0.1:$port" \
  -o "register read pc" -o "continue" -o "quit" >"$cl" 2>&1
# 判据两条都要，跟环回那步一致
if grep -q 'stop reason' "$cl" && grep -q 'exited with status = 0' "$cl"; then
  ok "连设备调试通了：host lldb 隔着 adb 连上设备的 lldb-server，停住、读了 pc、继续到正常退出"
  note "pc = $(grep -oE 'pc = 0x[0-9a-f]+' "$cl" | head -1 | sed 's/.*= //')"
  note "这条把 docs/LESSONS.md「没验的」表里最后一行验掉了。"
  exit 0
else
  printf '\n' >&2; sed 's/^/      /' "$cl" | tail -12 >&2
  die "连设备调试没通（上面是 lldb 的输出）"
fi
