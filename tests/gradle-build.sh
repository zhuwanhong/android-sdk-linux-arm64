#!/usr/bin/env bash
# 走 AGP／Gradle 那条路把 tests/ 下两个样例工程都编出来 —— README 第五节把
# 「两个工程都能在 ARM64 上 ./gradlew assembleRelease 出 APK，aapt2 dump badging
# 读得出包名」定成 M1 的验收标准，这个脚本就是跑那一条。
#
# 跟 hello-*/build.sh 那条手工流水线**编的是同一份源码**，但走的是完全不同的
# 工具链路径：AGP 自己解析 maven 上的 aapt2、自己找 cmake、自己调 llvm-strip。
# 手工那条全绿也不能推出这条能过 —— 事实上第一次跑就撞出四个坎，见 README。
#
# 用法：
#   tests/gradle-build.sh                用 $ANDROID_HOME
#   tests/gradle-build.sh /path/to/sdk   指定 SDK
#
# 要联网（下 Gradle 发行版、AGP 和它的依赖）。

set -uo pipefail

die()  { printf '\n  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1" >&2; }

# file(1) 是硬依赖：下面用 `case "$(file -b …)" in *ELF*)` 当闸门的地方，
# file 一缺就是空串 -> 全部 continue -> 检查空转报绿。实测过（见 docs/zh/LESSONS.md）。
command -v file >/dev/null || die "要 file(1)：sudo apt install -y file
    这个脚本靠它认二进制架构，缺了检查会静默空转。"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_rev=$(git -C "$HERE" log -1 --format='%h %ad' --date=short -- "${BASH_SOURCE[0]}" 2>/dev/null)
printf '  \033[2m%s @ %s\033[0m\n' "$(basename "${BASH_SOURCE[0]}")" "${_rev:-（不在 git 里）}"

SDK="${1:-${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}}"
[ -n "$SDK" ] && [ -d "$SDK" ] || die "找不到 SDK。设 ANDROID_HOME，或者传路径过来。"
SDK=$(cd "$SDK" && pwd)

BT=""; for d in "$SDK"/build-tools/*/; do BT="${d%/}"; done
[ -n "$BT" ] || die "$SDK 下没有 build-tools"
AAPT2="$BT/aapt2"
[ -x "$AAPT2" ] || die "找不到 $AAPT2"
"$AAPT2" version >/dev/null 2>&1 || die "$AAPT2 跑不起来（架构不对？）。
    这个包里的 aapt2 必须是本机能跑的那份 —— 见 docs/INSTALL.md。"

step "对谁动手"
note "SDK      $SDK"
# aapt2 的版本号是往 **stderr** 打的，不接 2>&1 这里会印成一对空括号
note "aapt2    $AAPT2（$("$AAPT2" version 2>&1)）"
note "java     $(java -version 2>&1 | head -1)"

# --------------------------------------------------------------------------
# local.properties：sdk.dir 必给；cmake.dir 见下。
step "写 local.properties"
{
  echo "sdk.dir=$SDK"
  # **cmake.dir 不设的后果是「悄悄下一份 x86_64 的 cmake 装进你的 SDK」**：
  # AGP 找不到它要的版本时会自己从 Google 的仓库装 cmake;3.22.1，而那个包
  # 只有 x86_64，跑起来报 `1: Syntax error: ")" unexpected`（是 sh 在解释
  # ELF 字节，不是 cmake 在说话）。指到系统那份就绕开了。
  if command -v cmake >/dev/null && command -v ninja >/dev/null; then
    echo "cmake.dir=/usr"
  else
    warn "系统里没有 cmake / ninja，hello-native 那个工程会挂。装：sudo apt install -y cmake ninja-build"
  fi
} > "$HERE/local.properties"
sed 's/^/    /' "$HERE/local.properties"

# --------------------------------------------------------------------------
step "跑 ./gradlew assembleRelease"
# 两个开关都不是可选项，理由分别是：
#
# 1. android.aapt2FromMavenOverride
#    AGP **不用** $ANDROID_HOME 里的 aapt2，它从 maven 解析
#    com.android.tools.build:aapt2:<ver>:linux，解开是 x86_64 ELF。
#
# 2. android.enableResourceOptimizations=false
#    AGP 的 optimizeXxxResources 调
#      aapt2 optimize … --resource-path-shortening-map=<路径>
#    而我们这份 aapt2（AOSP platform-tools-35.0.2）的参数解析器只认空格
#    形式，`--选项=值` 一律报 unknown option（cmd/Command.cpp 里是
#    `arg == flag.name` 精确匹配，没有拆 = 这一步）。它退出码 1，
#    **AGP 把这个失败吞了**：构建照报 BUILD SUCCESSFUL，产出的 APK 里
#    没有 AndroidManifest.xml 也没有 resources.arsc。
#    关掉这一步就绕开了。根治要换一份更新的 aapt2 —— 见 README 第三节。
FLAGS=( "-Pandroid.aapt2FromMavenOverride=$AAPT2" )

# 第 2 条那个开关**现在按需要加**，不写死：patches/aapt2/0001 打上之后
# aapt2 认 `--选项=值` 了，就不必关掉 optimize 那一步。
# 探法：拿那个选项空跑一次，看它是不是报 unknown option。
# **不走管道** —— `… | grep -q` 在 set -o pipefail 下会把命中判成失败
# （这个仓库栽过，见 docs/LESSONS.md 那张表）。
probe="$HERE/.aapt2-probe.txt"
"$AAPT2" optimize --resource-path-shortening-map=/dev/null > "$probe" 2>&1
if grep -q "unknown option" "$probe"; then
  warn "这份 aapt2 不认 --选项=值（没打 patches/aapt2/0001）。"
  note "AGP 的 optimize 步会传等号形式，被拒之后 **AGP 把失败吞掉**："
  note "构建报成功，而 APK 里没有 AndroidManifest.xml 和 resources.arsc。"
  note "所以这一轮先关掉那一步。根治：tools/build-aapt2.sh --fetch --build"
  FLAGS+=( "-Pandroid.enableResourceOptimizations=false" )
else
  note "aapt2 认 --选项=值，optimize 那步照常开着"
fi
rm -f "$probe"
( cd "$HERE" && ./gradlew --no-daemon assembleRelease "${FLAGS[@]}" ) \
  || die "gradle 挂了。上面有原文。"

# --------------------------------------------------------------------------
# **「BUILD SUCCESSFUL」不是判据。** 上面第 2 条那个坑就是构建报成功、
# APK 里资源全没了。所以每个产物都得拆开看。
step "验产物"
fail=0
check_apk() { # $1=工程名 $2=期望包名 $3=要不要有 arm64 的 .so
  local proj="$1" pkg="$2" want_so="$3" apk
  apk=$(find "$HERE/$proj/build-gradle" -name '*.apk' 2>/dev/null | head -1)
  [ -n "$apk" ] || { warn "$proj: 没找到 APK"; fail=1; return; }
  note "$proj → ${apk#$HERE/}（$(stat -c%s "$apk") 字节）"

  local names; names=$(unzip -l "$apk" 2>/dev/null)
  # 三样分开判，别让「文件不在」和「内容不对」共用一个出口
  case "$names" in *AndroidManifest.xml*) ;; *) warn "$proj: APK 里没有 AndroidManifest.xml"; fail=1 ;; esac
  case "$names" in *resources.arsc*)      ;; *) warn "$proj: APK 里没有 resources.arsc"; fail=1 ;; esac
  case "$names" in *classes.dex*)         ;; *) warn "$proj: APK 里没有 classes.dex"; fail=1 ;; esac

  local badging; badging=$("$AAPT2" dump badging "$apk" 2>&1) \
    || { warn "$proj: aapt2 读不了这个 APK：$(echo "$badging" | head -1)"; fail=1; return; }
  case "$badging" in
    *"name='$pkg'"*) ok "$proj: 包名 $pkg" ;;
    *) warn "$proj: 包名不是 $pkg：$(echo "$badging" | head -1)"; fail=1 ;;
  esac

  if [ "$want_so" = yes ]; then
    local so="$HERE/$proj/build-gradle/.so.tmp"
    if unzip -p "$apk" 'lib/arm64-v8a/*.so' > "$so" 2>/dev/null && [ -s "$so" ]; then
      case "$(file -b "$so")" in
        *"ARM aarch64"*) ok "$proj: lib/arm64-v8a/ 里的 .so 是 ARM aarch64" ;;
        *) warn "$proj: .so 架构不对：$(file -b "$so")"; fail=1 ;;
      esac
      # 光有 .so 不算数，得是我们这份源码编出来的
      _nm=$(nm -D --defined-only "$so" 2>/dev/null)   # 不走管道
      if grep -q Java_com_example_hellonative <<<"$_nm"; then
        ok "$proj: .so 里有 JNI 符号"
      else
        warn "$proj: .so 里没有 Java_com_example_hellonative_* 符号"; fail=1
      fi
    else
      warn "$proj: APK 里没有 lib/arm64-v8a/*.so"; fail=1
    fi
    rm -f "$so"
  fi
}

check_apk hello-jvm    com.example.hellojvm    no
check_apk hello-native com.example.hellonative yes

step "结果"
[ "$fail" = 0 ] || die "有产物没通过检查（见上）。"
ok "两个工程都用 ./gradlew assembleRelease 出了 APK，且产物逐项验过"
note "**没验**：装到真设备上跑。那要真机，走 tests/hello-*/build.sh --install。"
