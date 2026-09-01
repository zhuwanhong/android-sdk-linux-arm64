#!/usr/bin/env bash
# 自己编一份 aapt2 —— 这个仓库编出来的第一块自己的砖，也是**所有其他工具的入口**：
# 它取的那棵源码树（ReVanced 那套配方，18 个 pin 在 platform-tools-35.0.2 的 AOSP
# 子模块）后面每个 tools/build-*.sh 都在复用。
#
# 用的是 ReVanced/aapt2 的配方：18 个子模块 + 约 730 行 CMake + 3 个补丁，
# 绕开了 200+ GB 的 AOSP checkout。
#
# **不需要 x86_64 机器，也不需要 qemu。** 一度以为需要：它靠
# android.toolchain.cmake 找 prebuilt/<host-tag>/bin/clang，而 aarch64 上
# 那个目录本来不存在。tools/make-shim-toolchain.sh 把它建出来之后这个前提就没了。
#
# 编出来的是 **Android 目标**的静态二进制（跟上游配方一致），不是 glibc 二进制。
# 静态 bionic 二进制能在 ARM64 Linux 上跑，第三节验过。
#
# 跟别的工具的两点不同：
#   1. aapt2 是**上游 CMake 自己就有**的目标，所以 CMAKE_FILES 是空的 ——
#      不用往上游树里装 cmake/<工具>.cmake。
#   2. 取源码这段是它独有的（clone 整棵树 + 下 protoc），没抽进 build-common.sh。
#      公共骨架里的 common_fetch_tree 是给「在已有的树旁边再加一棵」用的。
#
# 用法：
#   tools/build-aapt2.sh              取源码 + 编 + 验
#   tools/build-aapt2.sh --fetch      只取源码（几 GB，网络慢可以先单独跑）
#   tools/build-aapt2.sh --build      只编
#   tools/build-aapt2.sh --verify     只验已编出来的那个
#   WORK=/path tools/build-aapt2.sh   换个工作目录（默认 <repo>/work）
#
# 环境变量：ALLOW_QEMU=1（见 tools/build-common.sh）
#
# 编译要跑几十分钟，建议放 tmux / screen 里。

TOOL=aapt2
CMAKE_FILES=()          # 上游自己就有这个目标，不用装
BIN_NAME=aapt2-arm64-v8a   # 上游给它的输出名带 ABI 后缀，跟目标名不一样
MIN_SIZE=1000000
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build-common.sh" "$@"

PROTOC_VER=21.12
UPSTREAM=https://github.com/ReVanced/aapt2

# ---------------------------------------------------------------- 取源码
if [ "$DO_FETCH" = 1 ]; then
  step "取源码"
  free_gb=$(df -BG --output=avail "$(dirname "$WORK")" 2>/dev/null | tail -1 | tr -dc '0-9')
  if [ -n "$free_gb" ] && [ "$free_gb" -lt 12 ]; then
    die "可用磁盘只有 ${free_gb}G。18 个 AOSP 子模块（frameworks/base 尤其大）
    加构建树，12G 是下限。腾点地方再来。"
  fi
  note "可用磁盘 ${free_gb:-?}G"
  mkdir -p "$WORK"

  if [ -d "$SRC/.git" ]; then
    note "$SRC 已存在，跳过 clone"
  else
    git clone --recurse-submodules --shallow-submodules --depth 1 "$UPSTREAM" "$SRC" \
      || die "clone 失败"
  fi
  ok "源码在 $SRC（$(du -sh "$SRC" 2>/dev/null | cut -f1)）"

  # protoc 跑在 host 上（把 .proto 生成 .cpp），所以要 aarch64 Linux 版。
  # 上游 README 让你下 linux-x86_64 那个 —— 在 ARM 机器上是错的。
  if [ ! -x "$PROTOC" ]; then
    case "$(uname -m)" in
      aarch64|arm64) pa=linux-aarch_64 ;;
      x86_64)        pa=linux-x86_64 ;;
      *) die "protoc 没有 $(uname -m) 的 release" ;;
    esac
    mkdir -p "$WORK/protoc"
    curl -fsSL -o "$WORK/protoc.zip" \
      "https://github.com/protocolbuffers/protobuf/releases/download/v$PROTOC_VER/protoc-$PROTOC_VER-$pa.zip" \
      || die "下载 protoc 失败"
    unzip -qo "$WORK/protoc.zip" -d "$WORK/protoc" || die "解压 protoc 失败"
    chmod +x "$PROTOC"
  fi
  "$PROTOC" --version >/dev/null 2>&1 || die "$PROTOC 跑不起来"
  ok "protoc $("$PROTOC" --version)"

  # -------------------------------------------------------------- 打我们的补丁
  # 跟 patches/ndk/ 同一个路子：**改完用脚本验，别手改**。
  # 现在只有一个，理由见 patches/aapt2/README.md。
  step "打 patches/aapt2/ 里的补丁"
  BASE="$SRC/submodules/base"
  [ -d "$BASE/tools/aapt2" ] || die "$BASE/tools/aapt2 不在 —— 源码树不完整"
  for pf in "$REPO"/patches/aapt2/*.patch; do
    [ -f "$pf" ] || continue
    n=$(basename "$pf")
    # 幂等：先试反向打，能反向说明已经打过了。
    if patch -d "$BASE" -p1 -R --dry-run -s -f < "$pf" >/dev/null 2>&1; then
      note "$n 已经打过了"
    elif patch -d "$BASE" -p1 --dry-run -s -f < "$pf" >/dev/null 2>&1; then
      patch -d "$BASE" -p1 -s < "$pf" || die "打 $n 失败"
      ok "$n"
    else
      die "$n 打不上，也不像已经打过 —— 上游那棵树动过？
    自己看：patch -d $BASE -p1 --dry-run < $pf"
    fi
  done
  # **打上了不等于有效**：确认那段代码真的在里面。
  grep -q 'has_inline_value' "$BASE/tools/aapt2/cmd/Command.cpp" \
    || die "补丁说打上了，但 Command.cpp 里找不到 has_inline_value —— 没真打上"
  ok "补丁都在（Command.cpp 认得 --选项=值 了）"
fi

# ---------------------------------------------------------------- 编
[ "$DO_BUILD" = 1 ] && common_build

# ---------------------------------------------------------------- 验
if [ "$DO_VERIFY" = 1 ]; then
  common_verify_prelude
  T="$WORK/verify-aapt2"; rm -rf "$T"; mkdir -p "$T/res/values" "$T/res/layout" "$T/out"

  cat > "$T/res/values/strings.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<resources>
  <string name="app_name">probe</string>
  <integer name="answer">42</integer>
  <color name="accent">#ffff3366</color>
</resources>
XML
  cat > "$T/res/layout/main.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<TextView xmlns:android="http://schemas.android.com/apk/res/android"
    android:id="@+id/hello"
    android:layout_width="match_parent" android:layout_height="wrap_content"
    android:textColor="@color/accent" android:text="@string/app_name"/>
XML
  cat > "$T/AndroidManifest.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.example.probe" android:versionCode="7">
  <application android:label="@string/app_name"/>
</manifest>
XML

  step "1/5  版本打得出来"
  v=$(run_tool version 2>&1 | head -1)
  case "$v" in
    *"Android Asset Packaging Tool"*) ok "$v" ;;
    *) die "版本那行不认识：$v" ;;
  esac

  step "2/5  先确认这条测试会红：坏掉的资源 XML 必须编不过"
  # 这是 aapt2 自己的真实错误路径（xml parser error），不是硬造的坏输入。
  # **原来这个脚本没有这一条** —— 只验到 compile/link 通不通，
  # 也就是说它坏成「什么都接受」时，测试照样绿。第五节第 5 条欠的账。
  mkdir -p "$T/badres/values"
  printf '<?xml version="1.0"?>\n<resources><string name="x">没闭合\n' > "$T/badres/values/bad.xml"
  if run_tool compile --dir "$T/badres" -o "$T/out/bad.zip" >/dev/null 2>&1; then
    die "没闭合的 XML 居然编过了 —— 那这条测试测不出任何东西。
    先修测试，别信结果。"
  fi
  ok "坏 XML 被拒了（测试有效）"

  step "3/5  compile：三类资源都得进去"
  run_tool compile --dir "$T/res" -o "$T/out/res.zip" || die "compile 失败"
  sz=$(stat -c%s "$T/out/res.zip")
  [ "$sz" -gt 200 ] || die "res.zip 只有 $sz 字节 —— 不像编进去了"
  # 「文件生成了」不算验收：里面得真有那三个资源编译出来的条目
  for f in values_strings.arsc.flat layout_main.xml.flat; do
    unzip -l "$T/out/res.zip" | grep -q "$f" || die "res.zip 里没有 $f —— 少编了一类资源
    看一眼：unzip -l $T/out/res.zip"
  done
  ok "res.zip $sz 字节，values 和 layout 两类都在"

  step "4/5  link：出 APK，而且 R.java 里要有那三个资源"
  AJ=""
  for j in "${ANDROID_HOME:-}"/platforms/*/android.jar; do [ -f "$j" ] && AJ="$j"; done
  if [ -z "$AJ" ]; then
    warn "没找到 android.jar（设一下 ANDROID_HOME），4/5 和 5/5 跳过 ——
    **那两条才是真干活的部分**。"
    common_verify_done ""
    exit 0
  fi
  run_tool link -I "$AJ" --manifest "$T/AndroidManifest.xml" \
      --java "$T/out" -o "$T/out/probe.apk" "$T/out/res.zip" || die "link 失败"
  R="$T/out/com/example/probe/R.java"
  [ -f "$R" ] || die "link 没生成 R.java（$R）—— --java 那条路没走通"
  # tests/hello-jvm 验的就是这一段，这里把它下沉到工具自己的验收里
  for sym in 'class string' 'class integer' 'class color' 'class layout' 'app_name' 'accent' 'hello'; do
    grep -q "$sym" "$R" || die "R.java 里没有「$sym」—— 资源没被正确登记
    看一眼：$R"
  done
  run_tool dump badging "$T/out/probe.apk" | grep -q "name='com.example.probe'" \
    || die "自己打的 APK，自己的 dump badging 读不出包名 —— 前后矛盾"
  unzip -l "$T/out/probe.apk" | grep -q 'resources.arsc' || die "APK 里没有 resources.arsc"
  ok "APK $(stat -c%s "$T/out/probe.apk") 字节，R.java 里 string/integer/color/layout 都在"

  step "5/5  交叉验证：换官方的 aapt2 读同一个 APK（能跑的话）"
  #
  # 两个独立实现互相印证。**注意版本可能不同**（SDK 里那个通常比我们源码 pin 的
  # platform-tools-35.0.2 新），所以比的是「读出来的包名一致」，不是逐字节比产物
  # —— 跨版本比字节不成立。
  #
  # **这一条在 ARM64 上基本做不成，而且那是应该的**：SDK 自带的 aapt2 是 x86_64 的，
  # 在 ARM64 上 exec 直接 126 —— 这正是这个项目存在的理由。所以它降级成一句说明，
  # 不是失败。只有在 x86_64 对照机上（第七节说的那台）才真的跑起来。
  #
  # 判「能不能用」**必须真执行一次**，不能只看可执行位。tests/common.sh 里
  # 早就写着这条（runs()），我第一版还是写成了 [ -x ]，在真 ARM64 上当场翻车：
  # 文件在、有可执行位、跑不了，输出为空，被判成「两个实现对不上」。
  runs_ok() { "$1" version >/dev/null 2>&1 || "$1" >/dev/null 2>&1; [ $? -lt 126 ]; }
  A2=""
  for d in "${ANDROID_HOME:-}"/build-tools/*/; do
    [ -x "${d}aapt2" ] && runs_ok "${d}aapt2" && A2="${d}aapt2"
  done
  if [ -n "$A2" ]; then
    n2=$("$A2" dump badging "$T/out/probe.apk" 2>/dev/null | grep -o "name='[^']*'" | head -1)
    case "$n2" in
      *com.example.probe*) ok "官方 aapt2（$("$A2" version 2>&1 | head -1)）读出来也是 $n2" ;;
      *) die "我们打的 APK，官方 aapt2 读出来是「$n2」—— 两个实现对不上，值得查" ;;
    esac
  else
    note "本机没有**跑得起来**的官方 aapt2，这条跳过。"
    note "  在 ARM64 上这是正常的：SDK 自带那个是 x86_64 的，exec 会得到 126。"
    note "  想做这条交叉验证，得在一台 x86_64 对照机上跑（第七节）。"
  fi

  common_verify_done "  用它跑测试：
    AAPT2=$BIN tests/hello-jvm/build.sh"
fi
