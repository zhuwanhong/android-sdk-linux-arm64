#!/usr/bin/env bash
# 纯 JVM 的样例工程 —— README 第五节要的两个之一，不碰 NDK。
#
# 跟 tests/hello-native 的分工：
#   hello-native  验 NDK host 工具链（ndk-build 编 C，JNI 调用）
#   hello-jvm     验资源那条链 —— **aapt2 link 生成 R.java** 这一段，
#                 hello-native 完全没走到（它的界面是代码里搭的）
#
#   aapt2 compile  编 layout / values 里的多种资源
#   aapt2 link     打包 **并生成 R.java**
#   javac          编 R.java + 业务代码
#   d8             转 dex
#   zipalign
#   apksigner
#
# 用法：
#   tests/hello-jvm/build.sh              只编
#   tests/hello-jvm/build.sh --install    编完装到设备并核对资源真的读到了
#   tests/hello-jvm/build.sh --clean

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../common.sh"
OUT="$HERE/build"

MODE=build
case "${1:-}" in
  --install) MODE=install ;;
  --clean)   rm -rf "$OUT"; echo "清理完毕"; exit 0 ;;
  "") ;;
  *) echo "不认识的参数：$1"; exit 1 ;;
esac

find_sdk
find_native_tools
report_tools

rm -rf "$OUT"; mkdir -p "$OUT"/{classes,gen,res,stage}

# ---------------------------------------------------------------- 1. 资源
step "1/5  aapt2 compile —— layout + values（多种资源类型）"
"$AAPT2" compile --dir "$HERE/res" -o "$OUT/res/res.zip" || die "aapt2 compile 失败"
ok "res.zip $(stat -c%s "$OUT/res/res.zip") 字节"

# ---------------------------------------------------------------- 2. link + R.java
step "2/5  aapt2 link —— 打包，并生成 R.java"
"$AAPT2" link -I "$ANDROID_JAR" \
    --manifest "$HERE/AndroidManifest.xml" \
    --java "$OUT/gen" \
    --min-sdk-version 21 --target-sdk-version 34 \
    -o "$OUT/unsigned.apk" "$OUT/res/res.zip" || die "aapt2 link 失败"
R="$OUT/gen/com/example/hellojvm/R.java"
[ -f "$R" ] || die "aapt2 没生成 R.java —— 这正是这个测试要验的那一步"
# R.java 里必须真的有那几类资源，不能只是个空壳
for sym in "class layout" "class id" "class array" "class color" "class string"; do
  grep -q "$sym" "$R" || die "R.java 里没有 $sym —— 资源没被正确登记"
done
ok "R.java 有 layout / id / array / color / string 五类"

# ---------------------------------------------------------------- 3. javac
step "3/5  javac —— 编 R.java 和业务代码"
# **-encoding UTF-8 不能省。** 这些 .java 里有中文注释，而 javac 不带这个
# 参数时用**平台默认编码** —— JDK 18 起才默认 UTF-8（JEP 400）。在 JDK 11/17
# 或者 locale 是 C 的机器上（裸容器就是），默认是 US-ASCII，于是每个中文字节
# 都报一条 `unmappable character`，一个文件就 120 个错。
# 实测：ubuntu:24.04（JDK 21）过，ubuntu:22.04（JDK 11）和 debian:12（JDK 17）全红。
javac --release 11 -encoding UTF-8 -classpath "$ANDROID_JAR" -d "$OUT/classes" \
      $(find "$HERE/java" "$OUT/gen" -name '*.java') || die "javac 失败"
ok "$(find "$OUT/classes" -name '*.class' | wc -l) 个 .class"

# ---------------------------------------------------------------- 4. dex
step "4/5  d8"
"$BT/d8" --min-api 21 --lib "$ANDROID_JAR" --output "$OUT/stage" \
         $(find "$OUT/classes" -name '*.class') || die "d8 失败"
[ -f "$OUT/stage/classes.dex" ] || die "d8 没产出 classes.dex"
ok "classes.dex $(stat -c%s "$OUT/stage/classes.dex") 字节"

# ---------------------------------------------------------------- 5. 打包签名
step "5/5  塞进 dex，对齐，签名"
( cd "$OUT/stage" && zip -q -r "$OUT/unsigned.apk" . ) || die "zip 失败"
align_and_sign "$OUT/unsigned.apk" "$OUT/app.apk" "$OUT"

verify_apk "$OUT/app.apk" "com.example.hellojvm"
# 纯 JVM 的包里不该有任何原生库 —— 有的话说明串味了
_l=$(unzip -l "$OUT/app.apk")   # 不走管道
if grep -q "\.so$" <<<"$_l"; then
  die "APK 里有 .so —— 这个工程不该碰 NDK"
fi
ok "APK 里没有原生库（本来就不该有）"
ok "APK 在 $OUT/app.apk"

[ "$MODE" = install ] || {
  echo
  echo "装到设备： tests/hello-jvm/build.sh --install"
  cat <<'TIP'

设备不在这台机器上（比如这是云实例）：APK 是这台编的，从哪装不影响结论。
把它拷到有设备的机器，然后在那台上跑：

  adb install -r app.apk \
    && adb logcat -c \
    && adb shell am start -n com.example.hellojvm/.MainActivity \
    && sleep 2 \
    && adb logcat -d -s hello-jvm:I | grep RESULT

RESULT 那行里应该有 items=abc
TIP
  exit 0
}

install_and_check "$OUT/app.apk" com.example.hellojvm .MainActivity hello-jvm "items=abc"
step "M1 的 hello-jvm 这条通过了"
