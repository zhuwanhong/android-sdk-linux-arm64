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
#
# **下载即接受 Google 的条款** —— 这些文件是他们分发的，本项目不转发。
set -uo pipefail
die() { printf '\n  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }
MANIFEST=https://dl.google.com/android/repository/repository2-3.xml

URL_ONLY=0
[ "${1:-}" = "--url-only" ] && { URL_ONLY=1; shift; }
PKG="${1:-}"; DEST="${2:-}"
[ -n "$PKG" ] || die "要一个包名，比如 ndk;27.1.12297006"
[ "$URL_ONLY" = 1 ] || [ -n "$DEST" ] || die "要一个目标目录"

command -v curl >/dev/null || die "要 curl"
man=$(mktemp); trap 'rm -f "$man"' EXIT
curl -fsSL -o "$man" "$MANIFEST" || die "取不到 manifest（离线？）"

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
