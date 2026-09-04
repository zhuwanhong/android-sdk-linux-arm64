#!/usr/bin/env bash
# 上游出新版本了吗？—— 只报告，不改任何东西。
#
# 为什么要有这条：docs/VERSIONS.md 定的策略是「3 个 LTS + 最新」，可**没人盯着
# 上游什么时候动**。实测栽过一次：hermesc 自己从 250829098.0.16 走到 .0.17，
# 是打包时偶然发现的 —— 而 RN 那边版本对不上会出字节码不兼容。
# 手写的「记得每季度看一眼」没人会真的看；跑得起来的检查才会。
#
# 退出码（跟 check-upstream-patches.sh 同一套约定）：
#   0  跟上游一致
#   10 上游走前面了 —— **好消息，不是失败**，但要人来决定跟不跟
#   2  没验成（离线、接口变了）
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); cd "$REPO"
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
moved(){ printf '  \033[33m!\033[0m %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }
skip() { printf '\n  \033[33m?\033[0m %s\n' "$1" >&2; exit 2; }

command -v curl >/dev/null || skip "要 curl"
changed=0

step "1/2  NDK：策略关心的两件事变了没有"
# **判据不是「上游有更新的版本」**。docs/VERSIONS.md 的策略是「跟生态实际钉的，
# 不跟最新」，所以「上游出了 r30」本身不构成行动理由 —— 按那个判据写的第一版
# 会每个月亮一次黄灯，而一条永远黄着的检查跟没有一样。
# 真正该报的只有两件：
#   1. 出现了**新的 LTS**，而我们没发（LTS 才是长期要跟的）；
#   2. **AGP 的默认 NDK 变了**，变成我们没发的版本（不发的话，没钉 ndkVersion
#      的模块会去下 x86_64 版，在 ARM64 上跑不了）。
ours=$(grep -oE 'android-ndk-[0-9.]+-linux' docs/RELEASE-NOTES.md | sed 's/android-ndk-//; s/-linux//' | sort -uV)
[ -n "$ours" ] || skip "docs/RELEASE-NOTES.md 里读不出我们发的 NDK 版本"
ours_majors=$(printf '%s\n' "$ours" | cut -d. -f1 | sort -un | tr '\n' ' ')
note "我们发的：$(printf '%s ' $ours)（主版本 $ours_majors）"

# --- 1a. 新 LTS ---
rev=$(curl -fsSL --max-time 60 https://developer.android.com/ndk/downloads/revision_history 2>/dev/null || true)
if [ -z "$rev" ]; then
  printf '  \033[33m?\033[0m 取不到 NDK 修订历史页 —— **LTS 这条没验成**\n'
else
  lts=$(printf '%s' "$rev" | python3 -c '
import sys, re, html
t = re.sub(r"<[^>]+>", " ", sys.stdin.read()); t = html.unescape(t)
print(" ".join(str(m) for m in sorted({int(x.group(1)) for x in re.finditer(r"\br(\d+)[a-z]?\s+LTS\b", t)})))
' 2>/dev/null || true)
  if [ -z "$lts" ]; then
    printf '  \033[33m?\033[0m 页面里解析不出 LTS 列表（改版了？）—— **这条没验成**\n'
  else
    note "Google 标记为 LTS 的主版本：$lts"
    missing=""
    for m in $lts; do
      case " $ours_majors " in *" $m "*) ;; *) missing="$missing r$m" ;; esac
    done
    newest_lts=$(printf '%s\n' $lts | tail -1)
    case " $ours_majors " in
      *" $newest_lts "*) ok "最新的 LTS（r$newest_lts）我们发了" ;;
      *) moved "出现了我们没发的 LTS：r$newest_lts"
         note "策略是「三个 LTS + 当前默认」，见 docs/VERSIONS.md。"
         changed=1 ;;
    esac
    [ -n "$missing" ] && note "（更旧的 LTS 没发：$missing —— 按 on request 处理，不算变化）"
  fi
fi

# --- 1b. AGP 的默认 NDK ---
meta=$(curl -fsSL --max-time 60 https://dl.google.com/dl/android/maven2/com/android/tools/build/gradle/maven-metadata.xml 2>/dev/null || true)
agp=$(printf '%s' "$meta" | grep -oE '<version>[0-9]+\.[0-9]+\.[0-9]+</version>' | sed 's/<[^>]*>//g' | sort -V | tail -1)
if [ -z "$agp" ]; then
  printf '  \033[33m?\033[0m 问不到最新的 AGP 版本 —— **这条没验成**\n'
else
  jar=$(mktemp); trap 'rm -f "$jar"' EXIT
  if curl -fsSL --max-time 300 -o "$jar" \
      "https://dl.google.com/dl/android/maven2/com/android/tools/build/gradle/$agp/gradle-$agp.jar" 2>/dev/null; then
    # 默认值是编进 class 里的字符串常量，没有别的地方能问
    agpndk=$(unzip -p "$jar" '*.class' 2>/dev/null | strings | grep -oE '\b[0-9]{2}\.[0-9]+\.[0-9]{7,8}\b' | sort -u | tail -1)
    if [ -z "$agpndk" ]; then
      printf '  \033[33m?\033[0m AGP %s 的 jar 里找不到 NDK 版本常量 —— **这条没验成**\n' "$agp"
    else
      note "AGP $agp 默认的 NDK：$agpndk"
      case "$ours" in
        *"$agpndk"*) ok "AGP 的默认值我们发了" ;;
        *) moved "AGP $agp 默认 $agpndk，我们没发这个版本"
           note "不发的话，没钉 ndkVersion 的模块会去下 x86_64 版，在这台上跑不了。"
           changed=1 ;;
      esac
    fi
  else
    printf '  \033[33m?\033[0m 下不到 AGP %s 的 jar（12 MB）—— **这条没验成**\n' "$agp"
  fi
fi

step "2/2  hermesc：npm 上的 hermes-compiler 走了没有"
# 我们钉的 tag 写死在 build-hermesc.sh 里
tag=$(sed -n 's/^HERMES_TAG="${HERMES_TAG:-\(.*\)}"$/\1/p' tools/build-hermesc.sh | head -1)
[ -n "$tag" ] || skip "build-hermesc.sh 里读不出 HERMES_TAG"
ourv=${tag#hermes-v}
note "我们钉的：$tag"
npmv=$(curl -fsSL --max-time 60 https://registry.npmjs.org/hermes-compiler/latest 2>/dev/null \
       | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))' 2>/dev/null || true)
if [ -z "$npmv" ]; then
  printf '  \033[33m?\033[0m 问不到 npm 上的版本 —— **这条没验成**\n'
else
  note "npm 上：$npmv"
  if [ "$npmv" = "$ourv" ]; then
    ok "跟 npm 上的一致"
  else
    moved "npm 上是 $npmv，我们钉的是 $ourv"
    note "RN 工程里 node_modules/react-native/sdks/.hermesv1version 写的就是它要的版本；"
    note "对不上会出字节码不兼容。要跟：改 build-hermesc.sh 的 HERMES_TAG 重编。"
    changed=1
  fi
fi

printf '\n'
[ "$changed" = 1 ] && { printf '\033[33m上游走前面了 —— 见上面标 ! 的那几行。这不是失败，是该做决定了。\033[0m\n'; exit 10; }
printf '\033[32m跟上游一致\033[0m\n'
