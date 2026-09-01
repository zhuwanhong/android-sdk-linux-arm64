#!/usr/bin/env bash
# 把 tools/make-dist.sh 摆好的那棵树做成一个 **sdkmanager 能识别的本地仓库**。
#
# **这是内部分发用的，不是公开发布用的** —— 理由见脚本结尾那段（包里必然含
# Google 的文件；而且只能装进还没有该包的干净 SDK 根）。对外发布走
# tarball + tools/install.sh。
#
# 每个包一个 zip，加一份 repository2-3.xml。README 第四节 M4 里那个「加分项」。
#
# ---------------------------------------------------------------------------
# 格式不猜，拿 Google 自己的文件当权威
#
#   https://dl.google.com/android/repository/repository2-3.xml   （412 KB）
#
# 从它身上量出来三件事：
#
# **一、schema 支持 linux/aarch64，但 Google 一个都没发。**
#   把那份文件里所有 <archive> 的 host-os/host-arch 组合数一遍：
#       linux   -         174      windows x64      61
#       windows -         174      macosx  aarch64  58   <- arch 字段是有的
#       macosx  -         171      windows x86      18
#       -       -          76
#       macosx  x64        61      **linux + aarch64：0 个**
#       linux   x64        61
#   也就是说这个项目的前提，在**分发元数据**这一层也成立：不是格式表达不了，
#   是没人发。我们这份 XML 填的就是那个空格。
#
# **二、zip 内部的顶层目录名。** 下了官方包看的，不是猜的：
#       platform-tools_r37.0.1-linux.zip -> platform-tools/...
#       build-tools_r36_linux.zip        -> android-16/...
#   sdkmanager 解压之后会把那个顶层目录整个改名成安装路径，所以名字本身不要紧，
#   但照着官方的形状做没坏处。
#
# **三、每个 remotePackage 的字段顺序**（XSD 是 sequence，顺序错了不合法）：
#       type-details / revision / display-name / uses-license / channelRef / archives
#
# ---------------------------------------------------------------------------
# 验到哪一步，说清楚
#
# **验了**：产出的 XML 用 **Google 官方的 XSD** 校验通过。那几个 xsd 是从
#   cmdline-tools 的 sdklib.core.jar 和 tools.repository.jar 里取出来的
#   （sdk-repository-03 / sdk-common-03 / repo-common-02 / generic-02）。
#   **校验器先在 Google 自己那份 repository2-3.xml 上校准过** —— 它必须通过，
#   否则说明是校验器搭错了，不是我们的 XML 有问题。
#
# **没验**：sdkmanager / Android Studio 真的去装它。试过两条路都不通：
#   - 新版 cmdline-tools（rev 23）的 sdkmanager 只是个壳，转发给新的 android CLI，
#     **当时的结论是「不认 SDK_TEST_BASE_URL」，那是错的** —— 2026-08-29 查清了：
#     它认，只是**基址必须以 `/` 结尾**。类里的 REPO_URL_PATTERN 是
#     `%srepository2-%d.xml`，少了斜杠就拼成 `http://host:8099repository2-3.xml`，
#     sdkmanager 判成非法直接忽略，一个请求都不发 —— 正是当初看到的现象。
#     对照实测（同一台、同一个服务）：
#         SDK_TEST_BASE_URL=http://127.0.0.1:8099   -> Warning: Ignoring invalid
#                                                      SDK_TEST_BASE_URL，请求数 0
#         SDK_TEST_BASE_URL=http://127.0.0.1:8099/  -> 列出我们的包，请求数 6
#
#   顺带把这一版 cmdline-tools 里的机制挖全了（从 AndroidSdkHandler.class 的
#   常量里读的，不是猜的）：
#         SDK_TEST_BASE_URL      环境变量
#         sdk.test.base.url      系统属性（JAVA_OPTS=-D… 传）
#         android.sdk.custom.url 另一条「自定义源」
#         repositories.cfg       用户站点文件（$ANDROID_SDK_HOME/.android/）
#
#   **现在这条是「装得上」，不只是「格式合法」**：--verify 会起一个本地 http
#   服务、拿真 sdkmanager 装进一个临时 sdk_root，再**执行**装进去的二进制。
#
# 用法：
#   tools/make-dist.sh            # 先摆好目录
#   tools/make-repo.sh            # 再做成仓库，输出到 $WORK/repo
#   （用起来：把 $WORK/repo 用任意 http 服务发出去，在 Android Studio 的
#     SDK Update Sites 里加那个 URL）

set -uo pipefail

DO_VERIFY=0
case "${1:-}" in --verify) DO_VERIFY=1; shift ;; esac

die()  { printf '\n  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1" >&2; }

# file(1) 是硬依赖：下面用 `case "$(file -b …)" in *ELF*)` 当闸门的地方，
# file 一缺就是空串 -> 全部 continue -> 检查空转报绿。实测过（见 docs/zh/LESSONS.md）。
command -v file >/dev/null || die "要 file(1)：sudo apt install -y file
    这个脚本靠它认二进制架构，缺了检查会静默空转。"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$REPO/work}"
DIST="${DIST:-$WORK/dist}"
OUTDIR="${OUT:-$WORK/repo}"

# 开头就把这个脚本自己是哪一版打出来 —— 「你跑的是哪一版」这个问题，
# 让它自己回答，别每次靠人去查。理由见 tools/build-common.sh 里同名函数。
_rev=$(git -C "$REPO" log -1 --format='%h %ad' --date=short -- "${BASH_SOURCE[0]}" 2>/dev/null)
printf '  \033[2m%s @ %s\033[0m\n' "$(basename "${BASH_SOURCE[0]}")" "${_rev:-（不在 git 里）}"

command -v zip >/dev/null    || die "没有 zip：sudo apt install -y zip"
command -v sha1sum >/dev/null || die "没有 sha1sum"
[ -d "$DIST/platform-tools" ] || die "找不到 $DIST/platform-tools。先跑：tools/make-dist.sh"

BT_DIR=""
for d in "$DIST"/build-tools/*/; do BT_DIR="${d%/}"; done
[ -n "$BT_DIR" ] || die "$DIST/build-tools 底下什么都没有"
BT_REV=$(basename "$BT_DIR")
PT_REV=$(sed -n 's/^Pkg.Revision=//p' "$DIST/platform-tools/source.properties")
[ -n "$PT_REV" ] || die "读不出 platform-tools 的 Pkg.Revision"

step "从哪儿来"
note "dist      $DIST"
note "build-tools     $BT_REV"
note "platform-tools  $PT_REV"

rm -rf "$OUTDIR"; mkdir -p "$OUTDIR"

# rev 拆成 major/minor/micro；XSD 里 major 必填，minor/micro 可选但官方都写全
split_rev() {  # $1=36.0.0 -> 打印 "36 0 0"
  local a b c; IFS=. read -r a b c <<EOF
$1
EOF
  printf '%s %s %s' "${a:-0}" "${b:-0}" "${c:-0}"
}

# $1=源目录 $2=zip 里的顶层目录名 $3=zip 文件名
mkzip() {
  local src="$1" top="$2" out="$3" t
  t=$(mktemp -d) || die "mktemp 失败"
  cp -a "$src" "$t/$top" || die "拷 $src 失败"
  ( cd "$t" && zip -q -r -X "$OUTDIR/$out" "$top" ) || die "打 $out 失败"
  rm -rf "$t"
  [ -s "$OUTDIR/$out" ] || die "$out 是空的"
}

step "打两个包"
# 顶层目录名照官方的形状：platform-tools 就叫 platform-tools，
# build-tools 官方那份叫 android-<N>（r36 的是 android-16）。
# sdkmanager 装的时候会把顶层目录改名成安装路径，所以这个名字不影响结果。
PT_ZIP="platform-tools_r${PT_REV}-linux-aarch64.zip"
BT_ZIP="build-tools_r${BT_REV}-linux-aarch64.zip"
mkzip "$DIST/platform-tools" "platform-tools" "$PT_ZIP"
mkzip "$BT_DIR"             "build-tools-$BT_REV" "$BT_ZIP"
ok "$PT_ZIP $(du -h "$OUTDIR/$PT_ZIP" | cut -f1)"
ok "$BT_ZIP $(du -h "$OUTDIR/$BT_ZIP" | cut -f1)"

step "写 repository2-3.xml"
emit_pkg() {  # $1=path $2=rev $3=显示名 $4=zip
  local maj min mic sz sha
  read -r maj min mic <<EOF
$(split_rev "$2")
EOF
  sz=$(stat -c%s "$OUTDIR/$4")
  sha=$(sha1sum "$OUTDIR/$4" | cut -d' ' -f1)
  cat <<EOF
  <remotePackage path="$1">
    <type-details xsi:type="generic:genericDetailsType"/>
    <revision>
      <major>$maj</major>
      <minor>$min</minor>
      <micro>$mic</micro>
    </revision>
    <display-name>$3</display-name>
    <uses-license ref="android-sdk-linux-arm64-license"/>
    <channelRef ref="channel-0"/>
    <archives>
      <archive>
        <complete>
          <size>$sz</size>
          <checksum type="sha1">$sha</checksum>
          <url>$4</url>
        </complete>
        <host-os>linux</host-os>
        <host-arch>aarch64</host-arch>
      </archive>
    </archives>
  </remotePackage>
EOF
}

{
  echo "<?xml version='1.0' encoding='utf-8'?>"
  echo "<!-- android-sdk-linux-arm64: 社区重建的 ARM64 Linux 版 SDK 组件。"
  echo "     不是 Google 发布的，也不冒充。每个包里带 PROVENANCE.txt，"
  echo "     逐个文件写清楚哪些是自己编的、哪些是从官方包原样拿的。 -->"
  echo "<sdk:sdk-repository xmlns:sdk=\"http://schemas.android.com/sdk/android/repo/repository2/03\" xmlns:common=\"http://schemas.android.com/repository/android/common/02\" xmlns:sdk-common=\"http://schemas.android.com/sdk/android/repo/common/03\" xmlns:generic=\"http://schemas.android.com/repository/android/generic/02\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">"
  echo "  <license id=\"android-sdk-linux-arm64-license\" type=\"text\">These packages are rebuilt from AOSP sources for linux/aarch64 by the"
  echo "android-sdk-linux-arm64 project. They are not published by Google. Each"
  echo "package contains a PROVENANCE.txt listing which files were rebuilt and which"
  echo "were taken unchanged from an official package. The original Android SDK terms"
  echo "still apply to the files taken from official packages.</license>"
  echo "  <channel id=\"channel-0\">stable</channel>"
  emit_pkg "platform-tools" "$PT_REV" "Android SDK Platform-Tools (linux/aarch64, community build)" "$PT_ZIP"
  emit_pkg "build-tools;$BT_REV" "$BT_REV" "Android SDK Build-Tools $BT_REV (linux/aarch64, community build)" "$BT_ZIP"
  echo "</sdk:sdk-repository>"
} > "$OUTDIR/repository2-3.xml"
ok "repository2-3.xml $(stat -c%s "$OUTDIR/repository2-3.xml") 字节"

step "验：拿 Google 官方的 XSD 校验"
# xsd 从 cmdline-tools 的 jar 里取。没有就跳过并**明说没验过**，不当通过。
XSDDIR="${XSD_DIR:-$WORK/sdk-xsd}"
# **先自己试着备齐**，别一上来就叫人手动搞 —— 手动那条路的结果就是没人搞，
# 这一步长期挂着「没校验过」。四份 xsd 在 cmdline-tools 的 jar 里，
# driver.xsd 我们自己带一份（tools/sdk-repo-driver.xsd）。
if [ ! -f "$XSDDIR/driver.xsd" ]; then
  cl=""
  for c in "${ANDROID_HOME:-}"/cmdline-tools/*/lib "${ANDROID_SDK_ROOT:-}"/cmdline-tools/*/lib \
           "${SDK:-/nonexistent}"/cmdline-tools/*/lib; do
    [ -f "$c/sdklib/sdklib.core.jar" ] && { cl="$c"; break; }
  done
  if [ -n "$cl" ] && command -v unzip >/dev/null; then
    mkdir -p "$XSDDIR"
    if unzip -qo -j "$cl/sdklib/sdklib.core.jar" 'xsd/sdk-repository-03.xsd' 'xsd/sdk-common-03.xsd' -d "$XSDDIR" 2>/dev/null &&
       unzip -qo -j "$cl/repository/tools.repository.jar" 'xsd/repo-common-02.xsd' 'xsd/generic-02.xsd' -d "$XSDDIR" 2>/dev/null; then
      cp "$REPO/tools/sdk-repo-driver.xsd" "$XSDDIR/driver.xsd"
      note "从 $cl 里的 jar 备齐了 XSD"
      # 校准基准：Google 官方那份 XML。取不到就跳过校准（下面那段会说明）
      [ -f "$XSDDIR/repository2-3.xml" ] || command -v curl >/dev/null &&
        curl -fsSL -o "$XSDDIR/repository2-3.xml" \
          https://dl.google.com/android/repository/repository2-3.xml 2>/dev/null || true
    fi
  fi
fi

if [ ! -f "$XSDDIR/driver.xsd" ]; then
  note "$XSDDIR 里没有 XSD，也没能自己备齐（要一份 cmdline-tools）："
  note "    mkdir -p $XSDDIR && cd $XSDDIR"
  note "    unzip -qo -j <cmdline-tools>/lib/sdklib/sdklib.core.jar 'xsd/sdk-repository-03.xsd' 'xsd/sdk-common-03.xsd'"
  note "    unzip -qo -j <cmdline-tools>/lib/repository/tools.repository.jar 'xsd/repo-common-02.xsd' 'xsd/generic-02.xsd'"
  note "    然后照 tools/make-repo.sh 开头那段写一个 driver.xsd"
  warn "**没校验过。** 这一步跳过不等于通过。"
elif ! command -v xmllint >/dev/null; then
  warn "没有 xmllint（sudo apt install -y libxml2-utils）。**没校验过。**"
else
  # **先在 Google 自己那份上校准**：它必须通过，否则是校验器搭错了。
  if [ -f "$XSDDIR/repository2-3.xml" ]; then
    xmllint --noout --schema "$XSDDIR/driver.xsd" "$XSDDIR/repository2-3.xml" >/dev/null 2>&1 \
      || die "校验器在 **Google 官方那份 XML** 上就没通过 —— 是 XSD 凑得不对，
    不是我们的 XML 有问题。先把 $XSDDIR 搭对。"
    ok "校准通过：Google 官方那份 repository2-3.xml 合法"
  else
    note "（$XSDDIR/repository2-3.xml 不在，跳过校准 —— 放一份官方的进去更稳）"
  fi
  out=$(xmllint --noout --schema "$XSDDIR/driver.xsd" "$OUTDIR/repository2-3.xml" 2>&1) \
    || { echo "$out" | head -10 >&2; die "我们这份 XML 不合法"; }
  ok "我们这份也合法"
fi

step "好了"
note "$OUTDIR"
note ""
# ---------------------------------------------------------------------------
step "⚠️ 这个仓库**不适合公开发布**"
note "两条硬理由，都是实测出来的："
note ""
note "1. **包里必然含 Google 的文件。** sdkmanager 的包是自带元数据的**完整单元**"
note "   （靠 source.properties 跟踪装了什么），所以 zip 里必须有 d8.jar /"
note "   apksigner / 包装脚本那些 —— 而它们受 Android SDK 许可条款约束。"
note "   拿 --ours-only 的 dist 做也不行：那里面没有 source.properties，"
note "   这个脚本会当场报「读不出 Pkg.Revision」。"
note ""
note "2. **它只能装进「还没有该包」的干净 SDK 根。** 2026-08-31 实测：往一个已装"
note "   官方 build-tools;36.0.0 的根上装，sdkmanager 认为同版本已安装、"
note "   **什么都不做** —— 我们的 aapt2 一个字节都没进去（服务端日志显示它确实"
note "   取到了 repository2-3.xml，是「无事可做」不是「没连上」）。"
note "   所以它不能当「覆盖官方那份」的手段。"
note ""
note "**那它有什么用**：一个已经有官方 SDK 授权的团队/机群，在**内部**建一次、"
note "内部分发 —— 新机器一条 sdkmanager 命令装到位，工程一个字不用改。"
note "对外发布走 tarball + tools/install.sh 那条（只发我们编的，官方部分装时取）。"
note ""
note "怎么用：把这个目录用任意 http 服务发出去，例如"
note "    (cd $OUTDIR && python3 -m http.server 8099)"
note "然后在 Android Studio 的 SDK Update Sites 里加 http://<主机>:8099/"
note ""
note "怎么验它真装得上：tools/make-repo.sh --verify"

# ---------------------------------------------------------------------------
# **--verify：真让 sdkmanager 装一遍。**
#
# 「XSD 校验通过」只说明格式合法，不说明装得上 —— 这两件事之间隔着
# sdkmanager 的整条解析和下载路径。所以这一步起个本地 http 服务、拿真
# sdkmanager 装进一个临时 sdk_root，最后**执行**装进去的二进制。
#
# 判据不是「下载完成」也不是「目录出现了」：那两样在包坏掉时照样成立。
verify_install() {
  step "验：让 sdkmanager 真装一遍"
  local sm=""
  for c in "${ANDROID_HOME:-}"/cmdline-tools/*/bin/sdkmanager "${ANDROID_SDK_ROOT:-}"/cmdline-tools/*/bin/sdkmanager; do
    [ -x "$c" ] && { sm="$c"; break; }
  done
  [ -n "$sm" ] || { warn "找不到 sdkmanager（cmdline-tools 没装），**这一步没验**"; return 0; }
  command -v python3 >/dev/null || { warn "没有 python3，起不了本地服务，**这一步没验**"; return 0; }

  local port=$(( 18000 + RANDOM % 10000 ))
  local root; root=$(mktemp -d)
  local hlog; hlog=$(mktemp)
  ( cd "$OUTDIR" && python3 -m http.server "$port" --bind 127.0.0.1 >"$hlog" 2>&1 ) &
  local hpid=$!
  local i=0
  while [ $i -lt 20 ]; do _p=$(ss -ltn 2>/dev/null); case "$_p" in *":$port"*) break ;; esac; i=$((i+1)); sleep 0.2 2>/dev/null || true; done

  # **基址结尾那个斜杠不能少。** REPO_URL_PATTERN 是 %srepository2-%d.xml，
  # 少了它拼出来是非法 URL，sdkmanager 直接忽略、一个请求都不发。
  # 当初正是栽在这里，误判成「不认这个环境变量」。
  local base="http://127.0.0.1:$port/"
  yes 2>/dev/null | SDK_TEST_BASE_URL="$base" timeout 300 "$sm" --sdk_root="$root" --licenses >/dev/null 2>&1
  SDK_TEST_BASE_URL="$base" timeout 600 "$sm" --sdk_root="$root" \
      --install "platform-tools" "build-tools;$BT_REV" >/dev/null 2>&1
  kill "$hpid" 2>/dev/null; wait "$hpid" 2>/dev/null

  local reqs; reqs=$(grep -c 'GET' "$hlog" 2>/dev/null || echo 0)
  local bad=0 n=0
  for f in "$root/platform-tools/adb" "$root/build-tools/$BT_REV/aapt2"; do
    if [ ! -x "$f" ]; then warn "$（basename "$f"）没装进去"; bad=1; continue; fi
    case "$(file -b "$f" 2>/dev/null)" in
      *"ARM aarch64"*) ;;
      *) warn "$(basename "$f") 不是 aarch64：$(file -b "$f" | cut -c1-40)"; bad=1; continue ;;
    esac
    # 「装进去了」和「能跑」是两回事 —— 第五节第 2 条。
    if "$f" version >/dev/null 2>&1 || "$f" --version >/dev/null 2>&1; then
      n=$((n+1))
    else
      warn "$(basename "$f") 装进去了但跑不起来"; bad=1
    fi
  done
  rm -rf "$root" "$hlog"
  [ "$reqs" -gt 0 ] || { warn "sdkmanager 一个请求都没发给本地服务 —— 基址没生效"; return 1; }
  [ "$bad" = 0 ] && [ "$n" = 2 ] \
    || { warn "装完的东西没通过检查（见上）"; return 1; }
  ok "sdkmanager 装上了：$reqs 个请求，2 个二进制都是 aarch64 且真跑过一遍"
}
[ "${DO_VERIFY:-0}" = 1 ] && verify_install
