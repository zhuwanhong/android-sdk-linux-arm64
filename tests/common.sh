# 被 tests/*/build.sh source，不单独执行。
#
# 放在这里的是「每个测试都要做一遍」的部分：找家伙什、签名、装到设备后核对
# logcat。各测试自己的编译步骤留在各自的 build.sh 里。

die()  { printf '\n  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }

# file(1) 是硬依赖：下面用 `case "$(file -b …)" in *ELF*)` 当闸门的地方，
# file 一缺就是空串 -> 全部 continue -> 检查空转报绿。实测过（见 docs/zh/LESSONS.md）。
command -v file >/dev/null || die "要 file(1)：sudo apt install -y file
    这个脚本靠它认二进制架构，缺了检查会静默空转。"

# 一个工具「能不能用」得真的执行一次才知道 —— SDK 自带的 aapt2/zipalign
# 文件都在，但都是 x86_64 的，在 ARM64 上是 exit 126。第五节第 2 条。
runs() { "$1" version >/dev/null 2>&1 || "$1" >/dev/null 2>&1; [ $? -lt 126 ]; }

# 注意：pick 在 $(...) 子 shell 里调，这里不能 die —— exit 只退子 shell，
# 外层会拿着空值继续跑。只 return，由外层判。
pick() { # $1=工具名  $2=环境变量指定的路径（可空）
  local name="$1" envval="$2" c
  if [ -n "$envval" ]; then
    runs "$envval" && { echo "$envval"; return 0; }
    return 1
  fi
  for c in "$(command -v "$name" 2>/dev/null)" "$BT/$name"; do
    [ -n "$c" ] && [ -x "$c" ] && runs "$c" && { echo "$c"; return 0; }
  done
  return 1
}

find_sdk() {
  SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  [ -n "$SDK" ] && [ -d "$SDK" ] || die "找不到 SDK，设一下 ANDROID_HOME"
  BT=""
  for d in "$SDK"/build-tools/*/; do BT="${d%/}"; done
  [ -n "$BT" ] || die "找不到 build-tools"
  ANDROID_JAR=""
  for j in "$SDK"/platforms/*/android.jar; do [ -f "$j" ] && ANDROID_JAR="$j"; done
  [ -n "$ANDROID_JAR" ] || die "找不到 android.jar，装一个 platform"
  [ -x "$BT/d8" ]        || die "找不到 $BT/d8"
  [ -x "$BT/apksigner" ] || die "找不到 $BT/apksigner"
  command -v javac >/dev/null || die "没有 javac，装个 JDK"
  command -v zip   >/dev/null || die "没有 zip：sudo apt install -y zip"
}

find_ndk() {  # 只有碰 NDK 的测试才调
  NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK:-}}"
  if [ -z "$NDK" ]; then for d in "$SDK"/ndk/*/; do NDK="${d%/}"; done; fi
  [ -n "$NDK" ] && [ -x "$NDK/ndk-build" ] || die "找不到 NDK 的 ndk-build"
}

find_native_tools() {
  AAPT2=$(pick aapt2 "${AAPT2:-}") || die "没有能在本机跑的 aapt2。
    SDK 里那个是 x86_64 的。用 AAPT2=/path/to/aarch64/aapt2 指过来。"
  ZIPALIGN=$(pick zipalign "${ZIPALIGN:-}") || die "没有能在本机跑的 zipalign。
    用 ZIPALIGN=/path/to/aarch64/zipalign 指过来。"
}

report_tools() {
  step "用的家伙什"
  note "SDK         $SDK"
  [ -n "${NDK:-}" ] && note "NDK         $NDK"
  note "build-tools $BT"
  note "android.jar $(basename "$(dirname "$ANDROID_JAR")")"
  note "aapt2       $AAPT2"
  note "zipalign    $ZIPALIGN"
  note "javac       $(javac -version 2>&1)"
}

# $1=未签名 apk  $2=输出 apk  $3=工作目录
align_and_sign() {
  local unsigned="$1" out="$2" work="$3" ks="$3/debug.keystore"
  "$ZIPALIGN" -f -p 4 "$unsigned" "$work/aligned.apk" || die "zipalign 失败"
  keytool -genkeypair -keystore "$ks" -alias a -storepass android -keypass android \
          -dname "CN=android-sdk-linux-arm64 test" -keyalg RSA -keysize 2048 \
          -validity 10000 >/dev/null 2>&1 || die "keytool 建密钥库失败"
  "$BT/apksigner" sign --ks "$ks" --ks-pass pass:android --key-pass pass:android \
          --out "$out" "$work/aligned.apk" || die "apksigner 失败"
  "$BT/apksigner" verify "$out" || die "签名验不过"
  ok "$(basename "$out") 已签名并通过校验"
}

# $1=apk  $2=期望的包名
verify_apk() {
  step "产物自检"
  "$AAPT2" dump badging "$1" | head -2 | sed 's/^/    /'
  "$AAPT2" dump badging "$1" | grep -q "name='$2'" || die "包名不是 $2"
  unzip -l "$1" | grep -E "classes.dex|\.so|resources.arsc" | sed 's/^/    /'
  note "大小 $(stat -c%s "$1") 字节"
}

# $1=apk  $2=包名  $3=Activity  $4=logcat tag  $5=期望在 RESULT 里出现的子串
install_and_check() {
  step "装到设备并核对运行结果"
  # ADB= 可以指定用哪一个，跟 AAPT2= / ZIPALIGN= 一个路子。
  # 想用自己编的那份：ADB=$WORK/out/adb tests/hello-native/build.sh --install
  # 不设就从 PATH 找。**用 runs() 而不是 [ -x ]** —— 第五节第 2 条，
  # 文件在、有可执行位、跑不起来是三件事（aapt2 那次的教训）。
  if [ -n "${ADB:-}" ]; then
    runs "$ADB" || die "ADB=$ADB 跑不起来（退出码 >= 126？可能是架构不对）"
  else
    ADB=$(command -v adb) || die "没有 adb：sudo apt install -y adb
    或者用自己编的：ADB=\$WORK/out/adb $0 --install"
    runs "$ADB" || die "PATH 里的 adb（$ADB）跑不起来"
  fi
  note "adb: $ADB（$("$ADB" --version 2>/dev/null | sed -n 2p)）"
  "$ADB" get-state >/dev/null 2>&1 || die "adb 看不到设备。

    云机器没 USB，走 ssh 反向隧道的话，**顺序很要紧**：
      1. 本机先杀掉自己的 adb 服务器：   adb kill-server
         （否则它占着 5037，ssh -R 绑不上，会打一行
          'remote port forwarding failed'，而 adb 连的还是本机这个空服务器）
      2. 有设备那台：adb start-server && adb devices   先确认看得到
      3. 有设备那台：ssh -R 5037:localhost:5037 <这台>
      4. 在那个 ssh 会话里重跑本脚本

    嫌麻烦就把 APK 拷到有设备的机器上装——产物是这台编的，从哪装不影响结论。"
  "$ADB" install -r "$1" || die "adb install 失败"
  ok "已安装"
  "$ADB" logcat -c
  "$ADB" shell am start -n "$2/$3" >/dev/null || die "启动失败"
  sleep 2
  local line
  line=$("$ADB" logcat -d -s "$4:I" | grep "RESULT" | tail -1)
  [ -n "$line" ] || die "logcat 里没有 RESULT —— 装上了但代码没跑到。
    看详细：adb logcat -d | grep -iE '$4|AndroidRuntime'"
  note "$line"
  case "$line" in
    *"$5"*) ok "跑起来了，而且结果对" ;;
    *) die "RESULT 出来了但内容不对，期望包含「$5」：$line" ;;
  esac
}
