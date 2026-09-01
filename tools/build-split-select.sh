#!/usr/bin/env bash
# 自己编一份 split-select。
#
# 它干什么：给一组 split APK 和一个目标设备配置，算出该装哪几个。Gradle 做
# ABI／密度分包时用；不分包就用不上 —— 所以它属于「补齐清单」，不像 aidl 那样
# 会卡住构建。
#
# 公共骨架在 tools/build-common.sh。跟 aapt(v1) 一样**一棵新源码树都不用取**，
# 源码在 submodules/base/tools/split-select/。
#
# **它链 libaapt**，那个静态库定义在 cmake/aapt.cmake 里，所以这个脚本会把
# aapt.cmake 和 split-select.cmake 一起装进上游的树（顺序要紧，aapt 在前）。
# 验收那步还会用到编出来的 aapt 去造样本 APK —— 没有就退化成只验前两条。
#
# 用法：
#   tools/build-split-select.sh              编 + 验
#   tools/build-split-select.sh --fetch      只查前提（没有新树要取）
#   tools/build-split-select.sh --build      只编
#   tools/build-split-select.sh --verify     只验已编出来的那个
#   WORK=/path tools/build-split-select.sh   换工作目录（默认 <repo>/work）
#
# 环境变量：
#   ALLOW_QEMU=1   非 aarch64 上用 qemu 跑那几条测试（**不算验收**）

TOOL=split-select
CMAKE_FILES=(aapt split-select)   # 顺序要紧：split-select 链 libaapt
MIN_SIZE=500000
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build-common.sh" "$@"

if [ "$DO_FETCH" = 1 ]; then
  step "查前提（split-select 不用另取源码树）"
  common_need_src
  common_need_protoc
  [ -f "$SRC/submodules/base/tools/split-select/Main.cpp" ] \
    || die "$SRC/submodules/base/tools/split-select/Main.cpp 不在 —— 上游的 base 子模块没取全？
    跑 tools/build-aapt2.sh --fetch 把源码树取齐。"
  ok "源码就在 submodules/base/tools/split-select/，不用另取"
fi

if [ "$DO_BUILD" = 1 ]; then
  [ -f "$SRC/submodules/base/tools/split-select/Main.cpp" ] || die "源码不在，先跑 --fetch"
  common_build
fi

if [ "$DO_VERIFY" = 1 ]; then
  common_verify_prelude

  T="$WORK/verify-split-select"; rm -rf "$T"; mkdir -p "$T/res/values" "$T/out" "$T/data"
  # 下面要用 aapt(v1) 造样本 APK，而它硬性要求这个变量，不设直接 abort。
  # 出处见 tools/build-aapt.sh 里那段注释。split-select 自己也走 libandroidfw，
  # 一并设上。
  export ANDROID_DATA="$T/data"

  step "1/4  --help 跑得起来"
  h=$(run_tool --help 2>&1) || die "--help 退出码非 0"
  case "$h" in
    *"--target <config>"*) ok "用法打印出来了" ;;
    *) die "--help 打的东西不认识：$(echo "$h" | head -1)" ;;
  esac

  step "2/4  先确认这条测试会红：base 不是 APK 必须失败"
  echo "这不是一个 APK" > "$T/notanapk.bin"
  if run_tool --target en-rUS-xhdpi:arm64-v8a --base "$T/notanapk.bin" >/dev/null 2>&1; then
    die "拿一个纯文本当 base APK，居然成功了 —— 那这条测试测不出任何东西。
    先修测试，别信结果。"
  fi
  ok "非 APK 的 base 被拒了（测试有效）"

  # 后面两条要一个真 APK。用这个仓库自己编的 aapt 造 —— 正好两个新工具互相印证：
  # aapt 打的包，split-select 读得懂。没编 aapt 就跳过（不为这条去用别人的产物）。
  AAPT="$WORK/out/aapt"
  AJ=""
  for j in "${ANDROID_HOME:-}"/platforms/*/android.jar; do [ -f "$j" ] && AJ="$j"; done
  if [ ! -x "$AAPT" ] || [ -z "$AJ" ]; then
    warn "缺 $WORK/out/aapt（跑 tools/build-aapt.sh）或 android.jar（设 ANDROID_HOME），
    3/4 和 4/4 跳过 —— **那两条才是真干活的部分**。"
    common_verify_done ""
    exit 0
  fi

  cat > "$T/AndroidManifest.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.example.splitprobe"
    android:versionCode="3" android:versionName="0.3">
  <application android:label="@string/app_name"/>
</manifest>
XML
  mkdir -p "$T/res/values-en"
  cat > "$T/res/values/strings.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<resources><string name="app_name">split probe</string></resources>
XML
  cat > "$T/res/values-en/strings.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<resources><string name="app_name">split probe (en)</string></resources>
XML

  # aapt 的 --split 会额外吐一个 <名字>_en.apk —— 那才是真的 split APK。
  # 只有 base 的话，下面第 4 步就退化成「什么都不选」，那是个太弱的断言。
  run_bin "$AAPT" package -f -M "$T/AndroidManifest.xml" -S "$T/res" -I "$AJ" \
      -F "$T/out/base.apk" --split en || die "拿自己编的 aapt 造样本 APK 失败"
  BASE="$T/out/base.apk"; SPLIT="$T/out/base_en.apk"
  [ -f "$SPLIT" ] || die "aapt --split en 没吐出 $SPLIT —— 样本没造成，后面两步测不出东西"

  step "3/4  真干活：--generate 得认出那个 en split"
  run_tool --generate --base "$BASE" --split "$SPLIT" > "$T/out/rules.json" 2>"$T/out/gen.err" \
    || { sed 's/^/    /' "$T/out/gen.err" >&2; die "--generate 失败"; }
  # 注意别拿 JSON 解析器验它：上游输出的 "args": [en] 里 en **没加引号**，
  # 不是合法 JSON（实测）。所以按结构查关键字段，不按语法解析。
  for pat in 'base_en.apk' '"property": "LANGUAGE"' '"op": "EQUALS"'; do
    grep -qF "$pat" "$T/out/rules.json" \
      || die "--generate 的输出里没有「$pat」—— 它没认出这是个按语言分的 split
    看一眼：$T/out/rules.json"
  done
  ok "规则认出了 LANGUAGE=en 的 split"

  step "4/4  **算得对**：同一组输入，两个目标配置要给出不同答案"
  # 这条比「跑起来了」硬：en 的设备该装那个 split，fr 的设备不该。
  got=$(run_tool --target en-rUS --base "$BASE" --split "$SPLIT" 2>&1) \
    || die "--target en-rUS 失败"
  case "$got" in
    *base_en.apk*) ok "en-rUS -> $(basename "$got")" ;;
    *) die "en-rUS 的设备应该选中 base_en.apk，实际选出「$got」" ;;
  esac
  got=$(run_tool --target fr-rFR --base "$BASE" --split "$SPLIT" 2>&1) \
    || die "--target fr-rFR 失败"
  [ -z "$got" ] || die "fr-rFR 的设备不该装 en 的 split，却选出了「$got」"
  ok "fr-rFR -> 什么都不选（对的）"

  common_verify_done "  用它挑该装哪个 split：
    $BIN --target <设备配置> --base base.apk --split a.apk --split b.apk"
fi
