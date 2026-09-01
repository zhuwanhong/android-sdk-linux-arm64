#!/usr/bin/env bash
# 自己编一份 aidl。M2 那批工具里最该先做的一个 —— 四个里**唯一会真的卡住一个
# app 构建**的：工程里只要有 .aidl（跨进程 service），没它就编不下去。
#
# 公共骨架在 tools/build-common.sh，几个工具共用。这里只留 aidl 自己的部分。
# 跟 zipalign 一样复用 build-aapt2.sh 取来的源码树和 build 目录，
# **先跑 tools/build-aapt2.sh（至少 --fetch）**。
#
# 比 zipalign 多两个前提：
#   flex + bison   aidl 的词法/语法分析器是 .ll / .yy，编之前要先生成
#   另一棵源码树   platform/system/tools/aidl（21 MB），上游那 18 个子模块里没有
#
# 用法：
#   tools/build-aidl.sh              取源码 + 编 + 验
#   tools/build-aidl.sh --fetch      只取那棵树
#   tools/build-aidl.sh --build      只编
#   tools/build-aidl.sh --verify     只验已编出来的那个
#   WORK=/path tools/build-aidl.sh   换工作目录（默认 <repo>/work，跟 aapt2 一致）
#
# 环境变量：
#   ALLOW_TAG_MISMATCH=1   上游子模块的 pin 跟 AOSP_TAG 对不上时也继续（默认拦下）
#   ALLOW_QEMU=1           非 aarch64 上用 qemu 跑那四条测试（**不算验收**）

TOOL=aidl
CMAKE_FILES=(aidl)
MIN_SIZE=500000
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build-common.sh" "$@"

# ---------------------------------------------------------------- 取源码
if [ "$DO_FETCH" = 1 ]; then
  step "取 aidl 的源码树"
  common_need_src
  common_need_protoc
  command -v git >/dev/null || die "没有 git"
  common_check_pin
  common_fetch_tree aidl system/tools/aidl main.cpp
  for f in aidl_language_l.ll aidl_language_y.yy; do
    [ -f "$SRC/submodules/aidl/$f" ] || die "取下来了但 $f 不在 —— 这个版本的 aidl 变结构了？"
  done
fi

# ---------------------------------------------------------------- 编
if [ "$DO_BUILD" = 1 ]; then
  [ -f "$SRC/submodules/aidl/main.cpp" ] || die "aidl 源码不在，先跑 --fetch"
  # 这两个是 aidl 独有的前提。缺了 cmake 的 find_package 也会在配置阶段报
  # REQUIRED 失败，但报得没这里清楚。
  command -v flex  >/dev/null || die "没有 flex：sudo apt install -y flex
    aidl 的词法分析器是 aidl_language_l.ll，编之前要先生成。"
  command -v bison >/dev/null || die "没有 bison：sudo apt install -y bison
    aidl 的语法分析器是 aidl_language_y.yy，编之前要先生成。"
  note "flex      $(flex --version 2>&1 | head -1)"
  note "bison     $(bison --version 2>&1 | head -1)"
  common_build
fi

# ---------------------------------------------------------------- 验
if [ "$DO_VERIFY" = 1 ]; then
  common_verify_prelude

  T="$WORK/verify-aidl"; rm -rf "$T"; mkdir -p "$T/src/com/example" "$T/out"

  # 合法的：一个真接口，两个方法，带 in 参数和返回值
  cat > "$T/src/com/example/ICalc.aidl" <<'AIDL'
package com.example;

interface ICalc {
    int add(int a, int b);
    String name();
}
AIDL

  # 故意写坏的：缺分号、类型不存在。第五节第 5 条 —— 先证明这条测试会红。
  cat > "$T/src/com/example/IBroken.aidl" <<'AIDL'
package com.example;

interface IBroken {
    NoSuchType oops(int a
}
AIDL

  step "1/4  版本横幅 —— 顺带确认 PLATFORM_SDK_VERSION 那个宏真的编进去了"
  # 坑：aidl 的 --version=VER 是「设置接口的版本号」，**不是**打印自己的版本，
  # 而且要带参数。版本横幅印在 usage 的第一行，--help 就能拿到（退出码 0）。
  ver=$(run_tool --help 2>&1 | head -1) || die "aidl --help 都跑不起来"
  note "$ver"
  case "$ver" in
    *"<UNKNOWN>"*) die "版本横幅是 <UNKNOWN> —— cmake/aidl.cmake 里的
    PLATFORM_SDK_VERSION 没生效，说明用的不是我们那份目标定义" ;;
    *"platform SDK version 35"*) ;;
    *) die "版本横幅不认识：$ver" ;;
  esac
  ok "$ver"

  step "2/4  先确认这条测试会红：语法坏掉的 .aidl 必须编不过"
  if run_tool -I"$T/src" -o "$T/out" "$T/src/com/example/IBroken.aidl" >/dev/null 2>&1; then
    die "写坏的 .aidl 居然编过了 —— 那这条测试测不出任何东西。
    要么上面那段坏语法其实合法，要么 aidl 根本没在解析。先修测试，别信结果。"
  fi
  ok "坏的 .aidl 被拒了（测试有效）"

  step "3/4  真干活：合法的 .aidl 生成 Java"
  run_tool -I"$T/src" -o "$T/out" "$T/src/com/example/ICalc.aidl" \
    || die "合法的 .aidl 编不过"
  J="$T/out/com/example/ICalc.java"
  [ -f "$J" ] || die "aidl 没报错，但 $J 不在"
  # 「文件存在」不算验收（第五节第 2 条），查生成的东西对不对
  for pat in 'interface ICalc' 'android.os.IInterface' 'abstract class Stub' \
             'int add(int a, int b)' 'java.lang.String name()' 'onTransact'; do
    grep -q "$pat" "$J" || die "生成的 Java 里没有「$pat」—— 生成器出问题了
    看一眼：$J"
  done
  ok "ICalc.java $(wc -l < "$J") 行，接口 / Stub / Proxy / onTransact 都在"

  step "4/4  生成的 Java 得真能编"
  AJ=""
  for j in "${ANDROID_HOME:-}"/platforms/*/android.jar; do [ -f "$j" ] && AJ="$j"; done
  if [ -n "$AJ" ] && command -v javac >/dev/null 2>&1; then
    mkdir -p "$T/classes"
    # javac 的输出憋着，过了就不打 —— 有些环境（比如设了 JAVA_TOOL_OPTIONS 的）
    # 会先吐一大段跟这件事无关的话，把真正的结果淹掉。
    if ! javac -nowarn -cp "$AJ" -d "$T/classes" "$J" > "$T/javac.log" 2>&1; then
      sed 's/^/    /' "$T/javac.log" >&2
      die "javac 编不过生成的 Java —— 文本对了但不合法"
    fi
    [ -f "$T/classes/com/example/ICalc.class" ] \
      || die "javac 没报错，但 ICalc.class 不在"
    ok "javac 过了，$(ls "$T/classes/com/example/" | wc -l) 个 class"
  else
    note "没有 javac 或 android.jar，跳过这步（只验到生成的文本对）"
  fi

  common_verify_done "  工程里有 .aidl 时这样用：
    $BIN -I<你的 aidl 目录> -o <生成目录> path/to/IFoo.aidl"
fi
