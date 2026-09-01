#!/usr/bin/env bash
# 带原生库的样例工程 —— README 第五节要的两个之一。
#
# **唯一能验证 NDK host 工具链真的能编 C 的路径。** 跟 tests/hello-jvm 的分工：
#   hello-native  ndk-build 编 C，JNI 被调用并算对
#   hello-jvm     资源那条链，尤其 aapt2 link 生成 R.java（这里没走到）
#
#   ndk-build   编 libhellonative.so  <- NDK host 工具链，M1 的核心
#   javac / d8  Java 那半
#   aapt2       打包（这里不需要 R.java，界面是代码里搭的）
#   zipalign / apksigner
#
# 用法：
#   tests/hello-native/build.sh              只编
#   tests/hello-native/build.sh --install    编完装到设备并核对原生代码真被调用
#   tests/hello-native/build.sh --clean

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../common.sh"
OUT="$HERE/build"

MODE=build
case "${1:-}" in
  --install) MODE=install ;;
  --clean)   rm -rf "$OUT" "$HERE/libs" "$HERE/obj"; echo "清理完毕"; exit 0 ;;
  "") ;;
  *) echo "不认识的参数：$1"; exit 1 ;;
esac

find_sdk
find_ndk
find_native_tools
report_tools

rm -rf "$OUT"; mkdir -p "$OUT"/{classes,res,stage/lib/arm64-v8a}

# ---------------------------------------------------------------- 1. 原生库
step "1/5  ndk-build —— 这一步用的就是 NDK 的 host 工具链"
# **故意不传 NDK_HOST_PYTHON。** 那一度是 python3 还没编出来时的绕过措施，
# 现在 tools/build-python.sh 编出来了、也装进工具链了，再传就是拿系统的
# python 把「工具链自不自足」这件事盖住 —— 而那正是要验的。
# 真缺 python 的时候不会静默降级：patches/ndk/0005 让 init.mk 直接 $(error)。
# 用官方 x86_64 NDK 试的话，自己 export NDK_HOST_PYTHON=$(command -v python3)。
( cd "$HERE" && "$NDK/ndk-build" NDK_PROJECT_PATH="$HERE" \
    NDK_APPLICATION_MK="$HERE/jni/Application.mk" ) \
  || die "ndk-build 失败 —— host 工具链有问题，先跑 tools/verify-claims.sh
    要是报的是找不到 Python：这份 NDK 的工具链里没有自足的 python3。
    补上（tools/build-python.sh）或者自己传 NDK_HOST_PYTHON=\$(command -v python3)。"
SO="$HERE/libs/arm64-v8a/libhellonative.so"
[ -f "$SO" ] || die "ndk-build 没报错，但产物 $SO 不在"
case "$(file -b "$SO")" in
  *"ARM aarch64"*) ok "libhellonative.so 是 ARM aarch64" ;;
  *) die "产出的不是 aarch64：$(file -b "$SO")" ;;
esac
cp "$SO" "$OUT/stage/lib/arm64-v8a/"

# ---------------------------------------------------------------- 2. Java
step "2/5  javac"
# **-encoding UTF-8 不能省。** 这些 .java 里有中文注释，而 javac 不带这个
# 参数时用**平台默认编码** —— JDK 18 起才默认 UTF-8（JEP 400）。在 JDK 11/17
# 或者 locale 是 C 的机器上（裸容器就是），默认是 US-ASCII，于是每个中文字节
# 都报一条 `unmappable character`，一个文件就 120 个错。
# 实测：ubuntu:24.04（JDK 21）过，ubuntu:22.04（JDK 11）和 debian:12（JDK 17）全红。
javac --release 11 -encoding UTF-8 -classpath "$ANDROID_JAR" -d "$OUT/classes" \
      $(find "$HERE/java" -name '*.java') || die "javac 失败"
ok "$(find "$OUT/classes" -name '*.class' | wc -l) 个 .class"

# ---------------------------------------------------------------- 3. dex
step "3/5  d8"
"$BT/d8" --min-api 21 --lib "$ANDROID_JAR" --output "$OUT/stage" \
         $(find "$OUT/classes" -name '*.class') || die "d8 失败"
[ -f "$OUT/stage/classes.dex" ] || die "d8 没产出 classes.dex"
ok "classes.dex $(stat -c%s "$OUT/stage/classes.dex") 字节"

# ---------------------------------------------------------------- 4. 资源
step "4/5  aapt2 compile + link"
"$AAPT2" compile --dir "$HERE/res" -o "$OUT/res/res.zip" || die "aapt2 compile 失败"
"$AAPT2" link -I "$ANDROID_JAR" \
    --manifest "$HERE/AndroidManifest.xml" \
    --min-sdk-version 21 --target-sdk-version 34 \
    -o "$OUT/unsigned.apk" "$OUT/res/res.zip" || die "aapt2 link 失败"
ok "unsigned.apk（资源 + manifest）"

# ---------------------------------------------------------------- 5. 打包签名
step "5/5  塞进 dex 和原生库，对齐，签名"
( cd "$OUT/stage" && zip -q -r "$OUT/unsigned.apk" . ) || die "zip 失败"
align_and_sign "$OUT/unsigned.apk" "$OUT/app.apk" "$OUT"

verify_apk "$OUT/app.apk" "com.example.hellonative"
# **不走管道。** `unzip -l … | grep -q` 在 set -o pipefail 下是竞态：
# grep -q 一命中就退出，unzip 收到 SIGPIPE，整条管道判成失败 —— **命中反而报错**。
# 2026-08-31 实测被它咬过一次：APK 里明明有那个 .so，检查却报「没有原生库」。
_l=$(unzip -l "$OUT/app.apk")
case "$_l" in *"lib/arm64-v8a/libhellonative.so"*) ;; *) die "APK 里没有原生库" ;; esac
ok "原生库在 APK 里"
ok "APK 在 $OUT/app.apk"

[ "$MODE" = install ] || {
  echo
  echo "装到设备： tests/hello-native/build.sh --install"
  cat <<'TIP'

设备不在这台机器上（比如这是云实例）：APK 是这台编的，从哪装不影响结论。
把它拷到有设备的机器，然后在那台上跑：

  adb install -r app.apk \
    && adb logcat -c \
    && adb shell am start -n com.example.hellonative/.MainActivity \
    && sleep 2 \
    && adb logcat -d -s hello-native:I | grep RESULT

RESULT 那行里应该有 20+22=42
TIP
  echo "（云上没 USB：把 $OUT/app.apk 拷到有设备的机器上装，"
  echo "  或者从那台机器 ssh -R 5037:localhost:5037 过来）"
  exit 0
}

install_and_check "$OUT/app.apk" com.example.hellonative .MainActivity \
                  hello-native "20+22=42"
step "M1 的 hello-native 这条通过了"
