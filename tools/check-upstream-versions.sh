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

step "1/2  NDK：上游有没有比我们发的更新的"
# 我们发了哪些：从 docs/RELEASE-NOTES.md 的产物表里读文件名，别再单独维护一份清单。
ours=$(grep -oE 'android-ndk-[0-9.]+-linux' docs/RELEASE-NOTES.md | sed 's/android-ndk-//; s/-linux//' | sort -uV)
[ -n "$ours" ] || skip "docs/RELEASE-NOTES.md 里读不出我们发的 NDK 版本"
newest_ours=$(printf '%s\n' "$ours" | tail -1)
note "我们发的：$(printf '%s ' $ours)"

# **不自己解 manifest**：全仓只许 tools/fetch-google-package.sh 碰它
# （ci-checks 第 7 项守着这条）。频道过滤、id 到名字的映射都在那边。
up=$(tools/fetch-google-package.sh --list-stable ndk) \
  || skip "问不到上游的 NDK 列表（离线？）"
[ -n "$up" ] || skip "stable 频道里一个 ndk 都没有 —— manifest 格式变了？"
newest_up=$(printf '%s\n' "$up" | tail -1)
note "上游 stable 最新：$newest_up（stable 频道共 $(printf '%s\n' "$up" | wc -l) 个）"

if [ "$newest_up" = "$newest_ours" ]; then
  ok "我们发的就是上游最新的"
else
  # 只有「上游确实更新」才报；我们发的比上游新是不可能的，真出现说明解析错了
  if [ "$(printf '%s\n%s\n' "$newest_ours" "$newest_up" | sort -V | tail -1)" = "$newest_up" ]; then
    moved "上游有更新的 NDK：$newest_up（我们最新发的是 $newest_ours）"
    note "跟不跟看 docs/VERSIONS.md 的策略（3 个 LTS + 最新）。"
    note "要跟的话：docs/RELEASING.md 最后那个附录（ndk_only 那套）。"
    changed=1
  else
    ok "我们发的 $newest_ours 不比上游旧"
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
