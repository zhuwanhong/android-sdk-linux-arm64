#!/usr/bin/env bash
# 造 adb 需要的两个生成头文件：deployagent.inc 和 deployagentscript.inc。
#
# **这是这个仓库里唯一一处「构建里嵌一个 Java 子构建」。** 值得说清楚为什么。
#
# packages/modules/adb/Android.bp 里 adb 的 generated_headers 有两项：
#
#     genrule { name: "bin2c_fastdeployagentscript", out: ["deployagentscript.inc"],
#               srcs: ["fastdeploy/deployagent/deployagent.sh"],
#               cmd: "(echo 'unsigned char kDeployAgentScript[] = {' && xxd -i <$(in) && echo '};') > $(out)" }
#     genrule { name: "bin2c_fastdeployagent", out: ["deployagent.inc"],
#               srcs: [":deployagent"], cmd: 同上但变量名是 kDeployAgent }
#
# 第一个是一条 xxd。第二个的输入 `:deployagent` 是个 **java_binary 模块**。
# 它是什么，看 wrapper 脚本就清楚了（fastdeploy/deployagent/deployagent.sh）：
#
#     export CLASSPATH=$base/deployagent.jar
#     exec app_process $base com.android.fastdeploy.DeployAgent "$@"
#
# 也就是 kDeployAgent 那个字节数组是**一个 dex 过的 jar**，adb 在
# `adb install --fastdeploy` 时把它推到设备的 /data/local/tmp 跑起来。
#
# 所以要造它，得在构建里跑一遍：
#     protoc --java_out=lite  ApkEntry.proto      -> APKMetaData/APKDump 的 Java 类
#     javac                   91 + 1 + 4 个 .java -> .class
#     d8                      .class              -> classes.dex
#     zip                     classes.dex         -> deployagent.jar
#
# 那 91 个是 protobuf 的 Java lite 运行时，清单**照抄
# external/protobuf/Android.bp 里 libprotobuf-java-lite 的 srcs**，不是自己挑的。
#
# **不能用别人生成好的 deployagent.inc。** lzhiyong 的仓库里带着一份现成的
# （当补丁文件），那是别人的产物 —— README 第五节不许直接用。这个脚本存在的
# 理由就是这个。
#
# 用法：tools/gen-deployagent.sh [输出目录]
#       默认输出到 $WORK/aapt2/build/adb-gen/，cmake/adb.cmake 就在那儿找。

set -uo pipefail

die()  { printf '\n  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$REPO/work}"
SRC="$WORK/aapt2"
ADB="$SRC/submodules/adb"
PB="$SRC/submodules/protobuf"
GEN="${1:-$SRC/build/adb-gen}"
PROTOC="$WORK/protoc/bin/protoc"

step "查家伙什"
[ -d "$ADB/fastdeploy" ] || die "找不到 adb 源码（$ADB）。先跑 tools/build-adb.sh --fetch"
[ -f "$PB/Android.bp" ] || die "找不到 protobuf 源码（$PB）"
[ -x "$PROTOC" ] || die "找不到 protoc（$PROTOC）。它由 tools/build-aapt2.sh --fetch 下载"
command -v javac >/dev/null || die "没有 javac，装个 JDK"
command -v zip   >/dev/null || die "没有 zip：sudo apt install -y zip"
command -v python3 >/dev/null || die "没有 python3"

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
[ -n "$SDK" ] && [ -d "$SDK" ] || die "找不到 SDK，设一下 ANDROID_HOME（要 android.jar 和 d8）"
ANDROID_JAR=""
for j in "$SDK"/platforms/*/android.jar; do [ -f "$j" ] && ANDROID_JAR="$j"; done
[ -n "$ANDROID_JAR" ] || die "找不到 android.jar，装一个 platform"
# d8 是跟架构无关的 bash + jar，SDK 里那个直接能用（第 1.2 节）
D8=""
for d in "$SDK"/build-tools/*/; do [ -x "${d}d8" ] && D8="${d}d8"; done
[ -n "$D8" ] || die "找不到 d8"
ok "javac $(javac -version 2>&1 | head -1 | awk '{print $NF}')，d8 $D8"
note "android.jar $ANDROID_JAR"

rm -rf "$GEN"
mkdir -p "$GEN/java" "$GEN/classes" "$GEN/dex" || die "建不出 $GEN"

# ---------------------------------------------------------------------------
step "1/5  protoc —— ApkEntry.proto 的 Java lite 类"
# Android.bp 里 deployagent_lib 的 srcs 直接包含 "proto/**/*.proto" 且
# proto.type = lite，对应 protoc 的 --java_out=lite:
"$PROTOC" --proto_path="$ADB/fastdeploy/proto" --java_out=lite:"$GEN/java" \
    "$ADB/fastdeploy/proto/ApkEntry.proto" || die "protoc 失败"
n=$(find "$GEN/java" -name '*.java' | wc -l)
[ "$n" -gt 0 ] || die "protoc 说成功了，但一个 .java 都没生成"
ok "$n 个 .java（$(find "$GEN/java" -name '*.java' -printf '%f ' )）"

# ---------------------------------------------------------------------------
step "2/5  取 libprotobuf-java-lite 的源码清单（照抄 Android.bp，不自己挑）"
python3 - "$PB" > "$GEN/pb-srcs.txt" <<'PYSRC' || die "解析 Android.bp 失败"
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])
t = (root / 'Android.bp').read_text()
i = t.index('name: "libprotobuf-java-lite"')
m = re.search(r'srcs:\s*\[(.*?)\n    \]', t[i:], re.S)
if not m:
    sys.exit("Android.bp 里 libprotobuf-java-lite 的 srcs 读不出来")
srcs = [x.strip().strip('",') for x in m.group(1).split('\n') if '.java' in x]
missing = [s for s in srcs if not (root / s).exists()]
if missing:
    sys.exit(f"Android.bp 列了 {len(missing)} 个不存在的源文件，头几个：{missing[:3]}")
print('\n'.join(str(root / s) for s in srcs))
PYSRC
npb=$(wc -l < "$GEN/pb-srcs.txt")
[ "$npb" -gt 50 ] || die "只解析出 $npb 个 protobuf 源文件，太少了 —— Android.bp 的格式变了？"
ok "$npb 个"

# ---------------------------------------------------------------------------
step "3/5  javac"
# --release 11 跟 tests/hello-jvm/build.sh 一致。
# protobuf 的 UnsafeUtil.java 要 sun.misc.Unsafe —— 那在 JDK 自己的
# jdk.unsupported 模块里，不在 android.jar 里，所以 android.jar 只能放
# -classpath（补 android.util.Log），不能拿去当 -bootclasspath 把 JDK 挡掉。
find "$ADB/fastdeploy/deployagent/src" -name '*.java' >  "$GEN/srcs.txt"
find "$GEN/java" -name '*.java'                       >> "$GEN/srcs.txt"
cat "$GEN/pb-srcs.txt"                                >> "$GEN/srcs.txt"
note "共 $(wc -l < "$GEN/srcs.txt") 个 .java"
javac --release 11 -nowarn -classpath "$ANDROID_JAR" -d "$GEN/classes" \
      @"$GEN/srcs.txt" 2>"$GEN/javac.log" || { sed 's/^/    /' "$GEN/javac.log" >&2; die "javac 失败"; }
nc=$(find "$GEN/classes" -name '*.class' | wc -l)
[ "$nc" -gt 0 ] || die "javac 说成功了，但一个 .class 都没有"
ok "$nc 个 .class"

# ---------------------------------------------------------------------------
step "4/5  d8 —— 打成 dex"
# min-api 24：Android.bp 里 deployagent_lib / deployagent 都是 sdk_version: "24"
"$D8" --min-api 24 --lib "$ANDROID_JAR" --output "$GEN/dex" \
      $(find "$GEN/classes" -name '*.class') >"$GEN/d8.log" 2>&1 \
    || { sed 's/^/    /' "$GEN/d8.log" >&2; die "d8 失败"; }
[ -f "$GEN/dex/classes.dex" ] || die "d8 没产出 classes.dex"
ok "classes.dex $(stat -c%s "$GEN/dex/classes.dex") 字节"

# 拿**我们自己编的 dexdump**验一下这个 dex 是真的（有就用，没有就跳过）。
# 自己造的 dex 拿自己编的工具读，两边都在验证对方。
DEXDUMP="$WORK/out/dexdump"
if [ -x "$DEXDUMP" ] && [ "$(uname -m)" = aarch64 ]; then
  cls=$("$DEXDUMP" "$GEN/dex/classes.dex" 2>/dev/null | grep -c "^Class #") || cls=0
  [ "$cls" -gt 50 ] || die "自己编的 dexdump 只在这个 dex 里读到 $cls 个类，不对劲"
  ok "自己编的 dexdump 读出 $cls 个类"
else
  note "跳过 dexdump 交叉验证（要 aarch64 + $WORK/out/dexdump）"
fi

step "5/5  打成 jar，转成 C 数组"
( cd "$GEN/dex" && zip -q -X "$GEN/deployagent.jar" classes.dex ) || die "zip 失败"
[ -s "$GEN/deployagent.jar" ] || die "deployagent.jar 是空的"

# Android.bp 那两个 genrule 的 cmd 是
#     (echo 'unsigned char kXxx[] = {' && xxd -i <$(in) && echo '};') > $(out)
# 这里**不用 xxd**：它属于 vim-common，不是每台机器都有（容器里就没有），
# 而 python3 本来就是这个仓库的硬依赖。**要紧的是字节，不是排版** ——
# 生成的是同样的 C 数组，只是每行几个字节的排法可能跟 xxd 不同。
mkinc() {  # $1=输入文件  $2=数组名  $3=输出 .inc
  python3 - "$1" "$2" > "$3" <<'BIN2C' || die "生成 $3 失败"
import sys, pathlib
b = pathlib.Path(sys.argv[1]).read_bytes()
print(f"unsigned char {sys.argv[2]}[] = {{")
for i in range(0, len(b), 12):
    print("  " + ", ".join(f"0x{x:02x}" for x in b[i:i + 12]) + ("," if i + 12 < len(b) else ""))
print("};")
BIN2C
  grep -q "^unsigned char $2\[\] = {" "$3" || die "$3 的头一行不对"
  [ "$(wc -c < "$3")" -gt 100 ] || die "$3 太小了"
  # 数出来的字节数必须跟输入文件一样大 —— 少一个字节，adb 推给设备的 agent
  # 就是坏的，而且要到 `adb install --fastdeploy` 才发作。
  # 数 0x 的个数，不是数逗号 —— 末行不带逗号，数逗号会少一个。
  # 第一版就是数的逗号，被这条检查自己抓出来了（报 211346 vs 211347）。
  want=$(wc -c < "$1")
  got=$(grep -o '0x' "$3" | wc -l)
  [ "$got" = "$want" ] || die "$3 里有 $got 个字节，输入文件是 $want 字节 —— 对不上"
}
mkinc "$GEN/deployagent.jar" kDeployAgent       "$GEN/deployagent.inc"
mkinc "$ADB/fastdeploy/deployagent/deployagent.sh" kDeployAgentScript "$GEN/deployagentscript.inc"
ok "deployagent.jar $(stat -c%s "$GEN/deployagent.jar") 字节"
ok "deployagent.inc $(stat -c%s "$GEN/deployagent.inc") 字节"
ok "deployagentscript.inc $(stat -c%s "$GEN/deployagentscript.inc") 字节"

step "好了"
note "$GEN"
