#!/usr/bin/env bash
# 把两个 release 包装成一个能直接用的 $ANDROID_HOME，**一条命令**。
#
# ---------------------------------------------------------------------------
# 这个脚本存在的理由：**光解压不够用。**
#
# 解完包还有两件事不做就用不了，而且失败方式都不直观：
#
#   1. cmake / ninja / lldb / clangd / glslc 这些**发行版自己就有 ARM 版**，
#      我们不重编，靠 tools/link-system-tools.sh 接进来。不接的话 AGP 会
#      **自己去下一份 x86_64 的 cmake 装进你的 SDK**。
#
#   2. AGP **不用** $ANDROID_HOME 里的 aapt2 —— 它从 maven 解析
#      com.android.tools.build:aapt2:<ver>:linux，解开是 x86_64 ELF，
#      直接挂在 “AAPT2 …-linux Daemon #0: Daemon startup failed”。
#      要给 Gradle 一个属性指到我们这份。写进 ~/.gradle/gradle.properties
#      就对**所有**工程生效，用户不必改自己的工程。
#
#   3. 我们发布的包**只含自己从 AOSP 源码编的那 15 个二进制**（Apache-2.0）。
#      官方那部分（d8.jar / apksigner / 包装脚本 / renderscript 资源…）受
#      **Android SDK 许可条款**约束，我们不再分发 —— 由这个脚本从 Google 取，
#      **你在那一步接受的是 Google 的条款**。取回来之后把我们的二进制覆盖上去。
#
#   4. 覆盖完还要**扫一遍**：官方包里那些我们没重编、又跑不了的 x86_64 host
#      二进制（RenderScript 那几个）必须删掉。留着就是「文件在、一跑就错」。
#
# 最后跑一次自检 —— **装完当场自证，别让用户自己相信**。
#
# 用法：
#   tools/install.sh --sdk-root ~/Android/Sdk
#   tools/install.sh --sdk-root DIR --sdk-tgz A.tar.gz --ndk-tgz B.tar.gz
#
#   --build-tools 36.1.0 装成别的 build-tools 版本（默认用包里那个目录名）
#   --platform 36       顺带把 platforms/android-36 下下来（包里没有，见下）
#   --platform-from DIR  从已有的 SDK 拷 platforms/（离线机器走这条）
#   --no-gradle-props   不动 ~/.gradle/gradle.properties（那你得自己传 -P）
#   --no-verify         跳过最后的自检（不建议）
#   --yes               目标目录已存在时不再追问
#
# 退出码：0 装好并自证通过 / 1 出错 / 2 缺前提（没包、架构不对…）
set -uo pipefail

die()  { printf '\n  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }
need() { printf '\n  \033[31m✗\033[0m %s\n' "$1" >&2; exit 2; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }

# file(1) 是硬依赖：下面用 `case "$(file -b …)" in *ELF*)` 当闸门的地方，
# file 一缺就是空串 -> 全部 continue -> 检查空转报绿。实测过（见 docs/zh/LESSONS.md）。
command -v file >/dev/null || die "要 file(1)：sudo apt install -y file
    这个脚本靠它认二进制架构，缺了检查会静默空转。"

# 临时目录统一登记、退出时一起删。三处 mktemp -d 各解开一个官方包（NDK 那个
# 解开是 2 GB），走 die 那条路时原先全留在 /tmp 里 —— 装失败重试几次就把 /tmp 撑满。
TMPS=""
cleanup_tmps() { [ -n "$TMPS" ] && rm -rf $TMPS; return 0; }  # return 0：别让清理的成败影响脚本退出码
trap cleanup_tmps EXIT
mktmp() { local d; d=$(mktemp -d) || die "建不了临时目录"; TMPS="$TMPS $d"; printf '%s' "$d"; }

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SDK_ROOT=""; SDK_TGZ=""; NDK_TGZ=""; DO_PROPS=1; DO_VERIFY=1; ASSUME_YES=0
PLATFORM_API=""; PLATFORM_FROM=""; INCOMPLETE=0; BT_REV_WANT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --sdk-root) SDK_ROOT="${2:-}"; shift 2 ;;
    --sdk-tgz)  SDK_TGZ="${2:-}";  shift 2 ;;
    --ndk-tgz)  NDK_TGZ="${2:-}";  shift 2 ;;
    --build-tools) BT_REV_WANT="${2:-}"; shift 2 ;;
    --platform) PLATFORM_API="${2:-}"; shift 2 ;;
    --platform-from) PLATFORM_FROM="${2:-}"; shift 2 ;;
    --no-gradle-props) DO_PROPS=0; shift ;;
    --no-verify) DO_VERIFY=0; shift ;;
    --yes|-y)   ASSUME_YES=1; shift ;;
    -h|--help)  sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "不认识的参数：$1（看 --help）" ;;
  esac
done

step "先看这台机器行不行"
[ "$(uname -m)" = aarch64 ] || need "这些包是 ARM64 的，这台是 $(uname -m)。
    x86_64 上直接用 Google 官方的 SDK 就行，不需要这个项目。"
ok "aarch64"
for t in tar java; do command -v "$t" >/dev/null || need "没有 $t"; done
ok "tar / java 都在（java $(java -version 2>&1 | head -1 | tr -d '\r'))"

[ -n "$SDK_ROOT" ] || need "要指定装到哪：--sdk-root ~/Android/Sdk"
# **别把相对路径留到后面**：link-system-tools.sh 和 gradle.properties 里都要写绝对路径
mkdir -p "$SDK_ROOT" || die "建不了 $SDK_ROOT"
SDK_ROOT=$(cd "$SDK_ROOT" && pwd)

# 包在哪：没指定就在几个常见位置找一遍，找不到明说，别装作能继续
find_tgz() { # $1=通配
  local c
  for c in "$REPO"/$1 "$REPO"/dist/$1 "$PWD"/$1 "${WORK:-/nonexistent}"/$1; do
    [ -f "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}
[ -n "$SDK_TGZ" ] || SDK_TGZ=$(find_tgz 'android-sdk-linux-arm64-*.tar.gz') || true
[ -n "$NDK_TGZ" ] || NDK_TGZ=$(find_tgz 'android-ndk-*-linux-aarch64.tar.gz') || true
[ -n "$SDK_TGZ" ] && [ -f "$SDK_TGZ" ] || need "找不到 SDK 包，用 --sdk-tgz 指过来
    （文件名形如 android-sdk-linux-arm64-<版本>.tar.gz）"
[ -n "$NDK_TGZ" ] && [ -f "$NDK_TGZ" ] || need "找不到 NDK 包，用 --ndk-tgz 指过来
    （文件名形如 android-ndk-<版本>-linux-aarch64.tar.gz）"
note "SDK 包  $SDK_TGZ"
note "NDK 包  $NDK_TGZ"
note "装到    $SDK_ROOT"

# 目标已经有东西：说清楚会盖掉什么，再问
if [ -n "$(ls -A "$SDK_ROOT" 2>/dev/null)" ] && [ "$ASSUME_YES" != 1 ]; then
  warn "$SDK_ROOT 不是空的，里面有：$(ls "$SDK_ROOT" | head -6 | tr '\n' ' ')"
  note "解压会**按文件覆盖**（同名的换掉，其它的留着）。"
  note "确认就再跑一次加 --yes；先看看的话：tar -tzf '$SDK_TGZ' | head"
  exit 2
fi

step "解包"
tar -C "$SDK_ROOT" -xzf "$SDK_TGZ" || die "解 SDK 包失败"
ok "SDK → $SDK_ROOT"
tar -C "$SDK_ROOT" -xzf "$NDK_TGZ" || die "解 NDK 包失败"
ok "NDK → $SDK_ROOT/ndk/"

# ---------------------------------------------------------------- build-tools 版本
# 我们编的那 7 个二进制来自 AOSP 源码，**跟 build-tools 的版本号没有内在关系** ——
# 那个目录里真正跟版本绑的是 Google 的 d8.jar / apksigner / 包装脚本，而它们本来
# 就由这个脚本从 Google 取。所以想装成哪个版本，把目录改个名、取对应的官方包即可。
#
# 为什么要这个：Google 发着 82 个 build-tools 版本，而工程里 buildToolsVersion
# 是钉死的 —— 钉了别的版本，光有 36.0.0 是不够的（AGP 报 Failed to find Build
# Tools revision …）。
#
# **AGP 自己也有一个默认 buildToolsVersion**（AGP 9.3.2 是 36.0.0）。模块里不写
# buildToolsVersion 的话，它要的是那个默认值 —— SDK 里没有就报
#     Failed to install the following Android SDK packages as some licences
#     have not been accepted: build-tools;36.0.0
# 那句话很误导：**真实原因是「这个版本没装」，不是许可问题**。所以用 --build-tools
# 装了别的版本时，工程里每个模块都要显式钉上同一个版本。2026-08-31 实测：
# 装成 36.1.0、两个样例模块都钉 36.1.0 → AGP 整条路通，两个 APK 都出；
# 只钉一个 → 另一个模块按默认值要 36.0.0，构建失败。
#
# **没验过的部分要说清楚**：老版本 AGP 配我们这份（AOSP platform-tools-35.0.2
# 源码编的）aapt2，只在 36.x 上真跑过。实际影响可能小 —— AGP 本来就不用 SDK 里
# 的 aapt2，它从 maven 解析（第 5 步那个 override 指到我们这份）。
if [ -n "$BT_REV_WANT" ]; then
  cur=""
  for d in "$SDK_ROOT"/build-tools/*/; do [ -d "$d" ] && cur="$(basename "${d%/}")"; done
  if [ -n "$cur" ] && [ "$cur" != "$BT_REV_WANT" ]; then
    mv "$SDK_ROOT/build-tools/$cur" "$SDK_ROOT/build-tools/$BT_REV_WANT" \
      || die "把 build-tools/$cur 改名成 $BT_REV_WANT 失败"
    ok "我们的二进制放进 build-tools/$BT_REV_WANT（包里带的目录名是 $cur）"
  fi
fi

# ---------------------------------------------------------------------- 补全 NDK
# 我们发的 NDK 包同样只含自己编的那部分（工具链的 bin/lib/python3 + simpleperf
# 的 host 那半 + 两个说明桩）。官方那部分 —— sysroot、build/、sources/、meta/、
# 各 ABI 的运行时（lib/clang）—— 由这里从 Google 取，再打上我们的 host tag 补丁。
NDKDIR=$(ls -d "$SDK_ROOT"/ndk/*/ 2>/dev/null | head -1); NDKDIR="${NDKDIR%/}"
if [ -n "$NDKDIR" ] && [ ! -d "$NDKDIR/build/cmake" ]; then
  step "从 Google 取官方 NDK，补齐我们没发的那部分"
  note "**这一步你接受的是 Google 的条款**。我们只发自己从源码编的东西。"
  command -v unzip >/dev/null || need "要 unzip：sudo apt install -y unzip"
  ndkver=$(basename "$NDKDIR")
  tmp=$(mktmp)
  # 地址解析和下载收在 tools/fetch-google-package.sh 里 —— 原先这段 XML 解析
  # 在本脚本里抄了两遍、build-ndk-version.sh 一遍，三份各自会长歪。
  "$REPO/tools/fetch-google-package.sh" "ndk;$ndkver" "$tmp/x" || die "取官方 NDK 失败"
  off=$(ls -d "$tmp"/x/*/ | head -1)
  # **逐文件只补缺的**，不能整目录 cp：
  #   - 我们包里 simpleperf/bin/linux/x86_64 是**软链**（指向 aarch64），
  #     官方那儿同名是**目录** —— cp 拿目录盖软链会直接失败（实测撞过）。
  #   - 官方的 toolchains/llvm/prebuilt/linux-x86_64 有好几个 G，
  #     在 ARM64 上一个字节都用不上，**排除掉**；sysroot 和 lib/clang
  #     从下面那步直接从解包临时目录里嫁接，不必先拷进来。
  n_add=0
  while IFS= read -r f; do
    case "$f" in ./toolchains/llvm/prebuilt/linux-x86_64/*) continue ;; esac
    [ -e "$NDKDIR/$f" ] && continue          # 已经有（含经软链解析到的）就别动
    mkdir -p "$NDKDIR/$(dirname "$f")"
    cp -a "$off$f" "$NDKDIR/$f" && n_add=$((n_add+1))
  done < <(cd "$off" && find . \( -type f -o -type l \))
  ok "从官方补进来 $n_add 个文件（x86_64 工具链那 4 GB 排除在外）"
  # 兼容软链：NDK 自带的一些脚本写死 linux-x86_64 这个路径
  ln -sfn linux-aarch64 "$NDKDIR/toolchains/llvm/prebuilt/linux-x86_64"

  # sysroot 和 lib/clang 跟 host 架构无关，从官方自带的 linux-x86_64 那份嫁接
  # （build-llvm.sh 在开发机上做的也是这一步）
  X86="$off/toolchains/llvm/prebuilt/linux-x86_64"   # 官方解包的临时目录，不是装好的树
  TC="$NDKDIR/toolchains/llvm/prebuilt/linux-aarch64"
  [ -d "$X86/sysroot" ] || die "官方包里没有 $X86/sysroot —— NDK 结构变了？"
  rm -rf "$TC/sysroot" "$TC/lib/clang"
  cp -a "$X86/sysroot" "$TC/sysroot" || die "嫁接 sysroot 失败"
  mkdir -p "$TC/lib"; cp -a "$X86/lib/clang" "$TC/lib/clang" || die "嫁接 lib/clang 失败"
  ok "sysroot $(du -sh "$TC/sysroot" | cut -f1) / lib/clang $(du -sh "$TC/lib/clang" | cut -f1) 已嫁接"

  "$REPO/tools/patch-ndk.sh" "$NDKDIR" >/dev/null 2>&1 \
    && ok "打上 host tag 的补丁（patches/ndk/）" \
    || die "patch-ndk.sh 失败，单独跑一次看：$REPO/tools/patch-ndk.sh $NDKDIR"
  rm -rf "$tmp"
fi

# ---------------------------------------------------------------------- 官方那部分
# 我们的包里只有自己编的二进制，缺 d8.jar / apksigner / 包装脚本等等。
# 从 Google 取回来，再把我们的覆盖上去。
have_bt=$(ls -d "$SDK_ROOT"/build-tools/*/ 2>/dev/null | head -1)
if [ -n "$have_bt" ] && [ -f "$have_bt/lib/d8.jar" ]; then
  ok "官方那部分已经在了（$(basename "${have_bt%/}")）"
else
  step "从 Google 取官方 build-tools / platform-tools"
  note "**这一步你接受的是 Google 的条款** —— 那些文件是他们分发的，我们不转发。"
  command -v unzip >/dev/null || need "要 unzip：sudo apt install -y unzip"
  command -v curl  >/dev/null || need "要 curl"
  # 版本号从我们包里的目录名读，别写死
  btrev=$(ls "$SDK_ROOT/build-tools" 2>/dev/null | head -1)
  [ -n "$btrev" ] || die "解出来的包里没有 build-tools/<版本>/，包不对？"
  for pkg in "build-tools;$btrev" "platform-tools"; do
    tmp=$(mktmp)
    "$REPO/tools/fetch-google-package.sh" "$pkg" "$tmp/x" \
      || die "取 $pkg 失败（离线的话用 --from-sdk 指一份已有的 SDK）"
    d=$(ls -d "$tmp"/x/*/ | head -1)
    case "$pkg" in
      build-tools*) dest="$SDK_ROOT/build-tools/$btrev" ;;
      platform-tools) dest="$SDK_ROOT/platform-tools" ;;
    esac
    mkdir -p "$dest"
    # -n：**不覆盖已有的** —— 我们的二进制已经在那儿了，官方那份是 x86_64，
    # 覆盖回去就前功尽弃。
    cp -a -n "$d". "$dest/" 2>/dev/null || cp -rn "$d". "$dest/" || die "拷贝失败"
    rm -rf "$tmp"
    ok "$pkg 取回来了"
  done
fi

step "扫掉跑不了的 x86_64 host 二进制"
# 官方包里有一批我们没重编的 host 二进制（RenderScript 那几个，上游 Android 12
# 起就废弃了）。它们是 x86_64 的，在这台上一跑就 Exec format error。
# **留着比没有更糟** —— 「文件在、一跑就错」。
swept=0
while IFS= read -r f; do
  case "$f" in */lib/*|*/renderscript/lib/*) continue ;; esac   # 各 ABI 的目标产物，不是 host 的
  t=$(file -b "$f" 2>/dev/null); case "$t" in *ELF*) ;; *) continue ;; esac
  case "$t" in *"ARM aarch64"*) continue ;; esac
  rm -f "$f"; swept=$((swept+1))
  note "删掉 ${f#$SDK_ROOT/}（$(printf '%s' "$t" | cut -d, -f2)）"
done < <(find "$SDK_ROOT/build-tools" "$SDK_ROOT/platform-tools" -type f -perm -u+x 2>/dev/null)
[ "$swept" = 0 ] && ok "没有跑不了的 host 二进制" || ok "扫掉 $swept 个（都是我们不重编的，理由见 PROVENANCE.txt）"

# **算一次，两段都用。** 头一版把它算在「写 gradle 属性」那段里，加 --no-gradle-props
# 时后面的自检就撞上 `BT: unbound variable`（set -u 当场拦下，算它帮忙）。
BT=""
for d in "$SDK_ROOT"/build-tools/*/; do [ -d "$d" ] && BT="${d%/}"; done
[ -n "$BT" ] && [ -x "$BT/aapt2" ] || die "$SDK_ROOT 里没找到能用的 aapt2 —— 包解对了吗？"
note "build-tools $BT"

step "把发行版自带的那几个工具接进来"
# 不接的后果不是「少了几个工具」，是 AGP 自己下一份 x86_64 的 cmake 装进来。
ANDROID_HOME="$SDK_ROOT" "$REPO/tools/link-system-tools.sh" >/dev/null 2>&1 \
  && ok "cmake / ninja / lldb / clangd / glslc 已接（细节见 $SDK_ROOT/PROVENANCE-system-tools.txt）" \
  || warn "link-system-tools.sh 没全绿 —— 单独跑一次看它说什么：
    ANDROID_HOME=$SDK_ROOT $REPO/tools/link-system-tools.sh"

step "platforms/（包里没有，得单独补）"
# **这不是遗漏，是有意的**：platforms/android-XX/android.jar 是纯 Java + 数据，
# 跟架构无关，Google 那份任何机器都能用，我们不重新分发。
# 但**没有它整个 SDK 就用不了** —— aapt2 link 要 android.jar，AGP 也要。
# 所以装的时候必须处理，不能装完了让用户自己撞上「找不到 android.jar」。
have_platform=$(ls -d "$SDK_ROOT"/platforms/android-*/android.jar 2>/dev/null | head -1)
if [ -n "$have_platform" ]; then
  ok "已经有了：$(basename "$(dirname "$have_platform")")"
elif [ -n "$PLATFORM_FROM" ]; then
  src=$(ls -d "$PLATFORM_FROM"/platforms/android-*/ 2>/dev/null | tail -1)
  [ -n "$src" ] || die "$PLATFORM_FROM 里没有 platforms/android-*/"
  mkdir -p "$SDK_ROOT/platforms"
  cp -a "$src" "$SDK_ROOT/platforms/" || die "拷 platforms 失败"
  ok "从 $PLATFORM_FROM 拷了 $(basename "${src%/}")"
elif [ -n "$PLATFORM_API" ]; then
  command -v unzip >/dev/null || need "要 unzip：sudo apt install -y unzip"
  command -v curl  >/dev/null || need "要 curl"
  tmp=$(mktmp)
  # 地址不写死：平台包的修订号（platform-36_r02.zip 里那个 r02）会变。
  # 解析在 tools/fetch-google-package.sh 里，全仓就那一份。
  "$REPO/tools/fetch-google-package.sh" "platforms;android-$PLATFORM_API" "$tmp/x" \
    || die "取 platforms;android-$PLATFORM_API 失败"
  mkdir -p "$SDK_ROOT/platforms"
  d=$(ls -d "$tmp"/x/*/ | head -1)
  # **解出来的目录名是代号不是 API 号**（比如 API 36 解出来叫 android-16），
  # 而 Gradle/AGP 找的是 platforms/android-<API>。按包里的 source.properties 改名。
  api=$(sed -n 's/^AndroidVersion.ApiLevel=//p' "$d/source.properties" 2>/dev/null | tr -d ' \r')
  [ -n "$api" ] || api="$PLATFORM_API"
  rm -rf "$SDK_ROOT/platforms/android-$api"
  mv "$d" "$SDK_ROOT/platforms/android-$api" || die "挪不动"
  rm -rf "$tmp"
  if [ "$(basename "${d%/}")" = "android-$api" ]; then
    ok "装好 platforms/android-$api"
  else
    ok "装好 platforms/android-$api（zip 里原名 $(basename "${d%/}") —— 那是**代号**不是 API 号，按 source.properties 改过来了）"
  fi
else
  warn "没有 platforms/，SDK 现在还用不了（aapt2 link 和 AGP 都要 android.jar）。"
  note "在线：  tools/install.sh … --platform 36"
  note "离线：  tools/install.sh … --platform-from /path/to/别的SDK"
  note "或者自己下：见 docs/INSTALL.md 第 3 步"
  DO_VERIFY=0   # 端到端那步必挂，别拿它吓人
  # **不能就这么打「好了」退出 0。** 没有 platforms 的 SDK 是不能用的，
  # 报成功就是假绿 —— 用户下一步撞上「找不到 android.jar」还得回头查。
  INCOMPLETE=1
fi

if [ "$DO_PROPS" = 1 ]; then
  step "给 Gradle 写 aapt2 的指向"
  GP="${GRADLE_USER_HOME:-$HOME/.gradle}/gradle.properties"
  mkdir -p "$(dirname "$GP")"
  line="android.aapt2FromMavenOverride=$BT/aapt2"
  if [ -f "$GP" ] && grep -q '^android\.aapt2FromMavenOverride=' "$GP"; then
    cur=$(grep '^android\.aapt2FromMavenOverride=' "$GP" | head -1)
    if [ "$cur" = "$line" ]; then
      ok "已经有了：$GP"
    else
      warn "$GP 里已经有一条**别的**指向，没动它：
    现有：$cur
    我们的：$line"
    fi
  else
    printf '\n# android-sdk-linux-arm64：AGP 会从 maven 拉 x86_64 的 aapt2，指到本机这份\n%s\n' \
      "$line" >> "$GP" || die "写不了 $GP"
    ok "写进 $GP"
  fi
  note "不想要就删掉那行，或者装的时候加 --no-gradle-props"
fi

if [ "$DO_VERIFY" = 1 ]; then
  step "自检：真跑一遍，不看文件在不在"
  A2="$BT/aapt2"
  v=$("$A2" version 2>&1 | head -1); case "$v" in *"Android Asset Packaging Tool"*) ok "aapt2：$v";; *) die "aapt2 跑不起来：$v";; esac

  ADB="$SDK_ROOT/platform-tools/adb"
  if [ -x "$ADB" ]; then
    p=$(( 26000 + RANDOM % 6000 ))
    if "$ADB" -L "tcp:$p" start-server >/dev/null 2>&1; then
      "$ADB" -P "$p" kill-server >/dev/null 2>&1
      ok "adb：服务器起得来（用的是 $p 端口，没碰 5037）"
    else
      die "adb 起不了服务器 —— 这份包里的 adb 有问题（见 patches/adb/README.md）"
    fi
  fi

  CLANG=$(ls "$SDK_ROOT"/ndk/*/toolchains/llvm/prebuilt/linux-aarch64/bin/clang 2>/dev/null | head -1)
  if [ -n "$CLANG" ]; then
    v=$("$CLANG" --version 2>&1 | head -1)
    case "$v" in *"clang version"*) ok "NDK 的 clang：$(printf %s "$v" | cut -c1-60)…";; *) die "NDK 的 clang 跑不起来：$v";; esac
  fi

  # 最硬的一条：真编一个 APK 出来（手工链路，不需要网络）
  if [ -x "$REPO/tests/hello-native/build.sh" ]; then
    if ANDROID_HOME="$SDK_ROOT" "$REPO/tests/hello-native/build.sh" >/dev/null 2>&1; then
      ok "端到端：tests/hello-native 编出了带原生库的 APK"
    else
      die "端到端那步没过。单独跑一次看它挂在哪：
    ANDROID_HOME=$SDK_ROOT $REPO/tests/hello-native/build.sh"
    fi
  fi
fi

if [ "$INCOMPLETE" = 1 ]; then
  step "**没装完**"
  note "包解好了、系统工具也接了，但**缺 platforms/，现在还编不了东西**。"
  note "补上它（二选一）再来一次："
  note "  tools/install.sh --sdk-root $SDK_ROOT --platform 36"
  note "  tools/install.sh --sdk-root $SDK_ROOT --platform-from /path/to/别的SDK"
  exit 2
fi

step "好了"
note "export ANDROID_HOME=$SDK_ROOT"
note "export PATH=\$ANDROID_HOME/platform-tools:\$PATH"
note ""
note "**工程里每个带原生代码的模块都要钉 ndkVersion '\''$(ls "$SDK_ROOT/ndk" 2>/dev/null | head -1)'\''**"
note "  不钉的话 AGP 会按自己的默认值去下一个 NDK —— 那是 x86_64 的，在这台上跑不了。"
note ""
note "能做什么、不能做什么，按场景列在：$REPO/docs/PARITY.md"
note "走 AGP 那条路还要注意的两点，也在那份文件里。"
