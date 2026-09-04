#!/usr/bin/env bash
# 从 Google 的官方仓库取一个包，解到指定目录。
#
# 地址**问 manifest 要**，不写死 —— 包的修订号会变（platform-36_r02.zip 那个 r02
# 迟早过期）。同一段解析原先在 install.sh 里抄了两遍、build-ndk-version.sh 一遍，
# 三份各自会长歪，所以收成一个。
#
# **选 archive 时必须认 host-os**：每个包下面有 linux / macosx / windows 三个
# archive，只按顺序取会拿到 windows 那个（我写临时诊断脚本时就这么错过一次）。
#
# 用法：
#   tools/fetch-google-package.sh "ndk;27.1.12297006" /目标目录
#   tools/fetch-google-package.sh "build-tools;36.0.0" /目标目录
#   tools/fetch-google-package.sh "platforms;android-36" /目标目录
#   tools/fetch-google-package.sh --url-only "ndk;27.1.12297006"     # 只打印地址
#   tools/fetch-google-package.sh --list-stable ndk                  # 列 stable 频道的版本
#
# **下载即接受 Google 的条款** —— 这些文件是他们分发的，本项目不转发。
set -uo pipefail
die() { printf '\n  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }
MANIFEST=https://dl.google.com/android/repository/repository2-3.xml

URL_ONLY=0; LIST=0
[ "${1:-}" = "--url-only" ]   && { URL_ONLY=1; shift; }
[ "${1:-}" = "--list-stable" ] && { LIST=1; shift; }
PKG="${1:-}"; DEST="${2:-}"
[ -n "$PKG" ] || die "要一个包名，比如 ndk;27.1.12297006"
[ "$URL_ONLY" = 1 ] || [ "$LIST" = 1 ] || [ -n "$DEST" ] || die "要一个目标目录"

command -v curl >/dev/null || die "要 curl"
man=$(mktemp); trap 'rm -f "$man"' EXIT
curl -fsSL -o "$man" "$MANIFEST" || die "取不到 manifest（离线？）"

if [ "$LIST" = 1 ]; then
  # 列某一类包在 **stable 频道**里有哪些版本。
  # **必须按频道过滤**：manifest 里 stable/beta/dev/canary 混在一起，不过滤的话，
  # 上游一发预览版，调用方（check-upstream-versions.sh）就开始乱叫 —— 而一条会
  # 乱叫的检查用不了几次就没人看了。频道 id 到名字的映射也在 manifest 里，别写死。
  python3 - "$man" "$PKG" <<'PYEOF'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
prefix = sys.argv[2].rstrip(";") + ";"
chan = {c.get("id"): c.text for c in root.iter() if c.tag == "channel"}
out = set()
for p in root.iter():
    path = p.get("path") or ""
    if not (p.tag.endswith("remotePackage") and path.startswith(prefix)):
        continue
    ref = ""
    for e in p.iter():
        if e.tag == "channelRef":
            ref = e.get("ref") or ""
    if chan.get(ref) == "stable":
        out.add(path[len(prefix):])
def key(v):
    try: return [int(x) for x in v.split(".")]
    except ValueError: return [0]
print("\n".join(sorted(out, key=key)))
PYEOF
  exit 0
fi

url=$(python3 - "$man" "$PKG" <<'PYEOF'
import sys, xml.etree.ElementTree as ET
path = sys.argv[2]
root = ET.parse(sys.argv[1]).getroot()
best = None
for p in root.iter():
    if not (p.tag.endswith("remotePackage") and p.get("path") == path):
        continue
    for ar in p.iter():
        if ar.tag != "archive":
            continue
        host = ""
        for e in ar.iter():
            if e.tag == "host-os":
                host = e.text or ""
        urls = [e.text for e in ar.iter() if e.tag == "url" and e.text]
        # host-os 缺省 = 跟平台无关（platforms、build-tools 的 jar 那类）
        if urls and host in ("", "linux"):
            best = urls[0]
print(best or "")
PYEOF
) || die "解析 manifest 失败"
[ -n "$url" ] || die "manifest 里没有「$PKG」。看有哪些：
    curl -s $MANIFEST | grep -o 'path=\"[^\"]*\"' | sort -u | head -40"
case "$url" in http*) ;; *) url="https://dl.google.com/android/repository/$url" ;; esac

if [ "$URL_ONLY" = 1 ]; then printf '%s\n' "$url"; exit 0; fi

command -v unzip >/dev/null || die "要 unzip"
mkdir -p "$DEST" || die "建不了 $DEST"
tmp=$(mktemp -d)
printf '  取 %s\n     %s\n' "$PKG" "$url"
curl -fsSL -o "$tmp/p.zip" "$url" || { rm -rf "$tmp"; die "下载失败"; }
unzip -q "$tmp/p.zip" -d "$DEST" || { rm -rf "$tmp"; die "解压失败"; }
rm -rf "$tmp"
printf '  \033[32m✓\033[0m 解到 %s（%s）\n' "$DEST" "$(du -sh "$DEST" | cut -f1)"
