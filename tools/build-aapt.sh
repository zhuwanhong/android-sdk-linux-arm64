#!/usr/bin/env bash
# 自己编一份 aapt（v1）。
#
# **它跟 aapt2 不是一个东西。** Gradle 早换成 aapt2 了；v1 留着是因为 apktool
# 那类第三方工具还在调它，而且它在第 1.2 节那张 ELF 清单里 —— M2 要覆盖它。
#
# 公共骨架在 tools/build-common.sh。这个工具**一棵新源码树都不用取**：
# frameworks/base 本来就是上游那 18 个子模块之一，源码在 submodules/base/tools/aapt/。
# 所以只要先跑过 tools/build-aapt2.sh --fetch 就够了。
#
# 顺带产出 libaapt 这个静态库 —— split-select 也要用它（cmake/split-select.cmake）。
#
# 用法：
#   tools/build-aapt.sh              编 + 验
#   tools/build-aapt.sh --fetch      只查前提（没有新树要取）
#   tools/build-aapt.sh --build      只编
#   tools/build-aapt.sh --verify     只验已编出来的那个
#   WORK=/path tools/build-aapt.sh   换工作目录（默认 <repo>/work，跟 aapt2 一致）
#
# 环境变量：
#   ALLOW_QEMU=1   非 aarch64 上用 qemu 跑那几条测试（**不算验收**）

TOOL=aapt
CMAKE_FILES=(aapt)
MIN_SIZE=500000
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build-common.sh" "$@"

if [ "$DO_FETCH" = 1 ]; then
  step "查前提（aapt 不用另取源码树）"
  common_need_src
  common_need_protoc
  [ -f "$SRC/submodules/base/tools/aapt/Main.cpp" ] \
    || die "$SRC/submodules/base/tools/aapt/Main.cpp 不在 —— 上游的 base 子模块没取全？
    跑 tools/build-aapt2.sh --fetch 把源码树取齐。"
  ok "源码就在 submodules/base/tools/aapt/，不用另取"
fi

if [ "$DO_BUILD" = 1 ]; then
  [ -f "$SRC/submodules/base/tools/aapt/Main.cpp" ] || die "aapt 源码不在，先跑 --fetch"
  common_build
fi

if [ "$DO_VERIFY" = 1 ]; then
  common_verify_prelude

  T="$WORK/verify-aapt"; rm -rf "$T"; mkdir -p "$T/res/values" "$T/out" "$T/data"

  # **aapt v1 硬性要求 ANDROID_DATA**，不设直接 abort（不是报错退出）：
  #     ANDROID_DATA not set
  #     Aborted
  # 出处是 base/libs/androidfw/AssetManager.cpp:90 的
  #     LOG_ALWAYS_FATAL_IF(root == NULL, "ANDROID_DATA not set")
  # AOSP 自己的构建环境里这个变量本来就有，单独拿出来用就没有了。
  # aapt2 走的是另一套（AssetManager2），不吃这一条 —— 所以这是 v1 独有的坑。
  export ANDROID_DATA="$T/data"
  cat > "$T/AndroidManifest.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.example.aaptprobe"
    android:versionCode="7" android:versionName="0.7">
  <application android:label="@string/app_name"/>
</manifest>
XML
  cat > "$T/res/values/strings.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<resources><string name="app_name">aapt probe</string></resources>
XML

  step "1/4  版本"
  v=$(run_tool version 2>&1) || die "aapt version 跑不起来：$v"
  note "$v"
  case "$v" in
    *"Android Asset Packaging Tool"*) ok "$v" ;;
    *) die "版本那行不认识：$v" ;;
  esac

  step "2/4  先确认这条测试会红：喂它一个不是 APK 的文件必须失败"
  # 不需要 android.jar，所以这条自检在任何机器上都跑得到。
  echo "这不是一个 APK，一个字节都不像" > "$T/notanapk.bin"
  if run_tool dump badging "$T/notanapk.bin" >/dev/null 2>&1; then
    die "把一个纯文本当 APK 读，居然成功了 —— 那这条测试测不出任何东西。
    先修测试，别信结果。"
  fi
  ok "非 APK 被拒了（测试有效）"

  AJ=""
  for j in "${ANDROID_HOME:-}"/platforms/*/android.jar; do [ -f "$j" ] && AJ="$j"; done
  if [ -z "$AJ" ]; then
    warn "没找到 android.jar（设一下 ANDROID_HOME），3/4 和 4/4 跳过 ——
    **那两条才是真干活的部分**，只验到「跑得起来、认得出坏输入」。"
  else
    step "3/4  真干活：打一个 APK 出来"
    run_tool package -f -M "$T/AndroidManifest.xml" -S "$T/res" -I "$AJ" \
        -F "$T/out/probe.apk" || die "aapt package 失败"
    [ -f "$T/out/probe.apk" ] || die "package 没报错但 APK 不在"
    run_tool dump badging "$T/out/probe.apk" | grep -q "com.example.aaptprobe" \
      || die "自己打的 APK，自己的 dump badging 读不出包名 —— 前后矛盾"
    # 「文件存在」不算验收：资源真编进去了才算
    unzip -l "$T/out/probe.apk" | grep -q 'resources.arsc' \
      || die "APK 里没有 resources.arsc —— 资源那一步没真做"
    ok "probe.apk $(stat -c%s "$T/out/probe.apk") 字节，包名和 resources.arsc 都在"

    step "4/4  交叉验证：换 aapt2 读同一个 APK，包名要一致"
    # 两个独立实现互相印证。aapt2 是这个仓库自己编的（tools/build-aapt2.sh），
    # 没编就跳过 —— 不为这条去装别人的产物。
    A2="$WORK/out/aapt2"
    if [ -x "$A2" ]; then
      n2=$(run_bin "$A2" dump badging "$T/out/probe.apk" 2>/dev/null \
           | grep -o "name='[^']*'" | head -1)
      case "$n2" in
        *com.example.aaptprobe*) ok "aapt2 读出来也是 $n2" ;;
        *) die "aapt 打的 APK，aapt2 读出来是「$n2」—— 两个实现对不上，值得查" ;;
      esac
    else
      note "$A2 不在（先跑 tools/build-aapt2.sh），跳过交叉验证"
    fi
  fi

  common_verify_done "  用它打包（**ANDROID_DATA 必须设**，不设会 abort）：
    ANDROID_DATA=\$(mktemp -d) $BIN package -f -M AndroidManifest.xml -S res -I android.jar -F out.apk"
fi
