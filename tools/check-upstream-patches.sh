#!/usr/bin/env bash
# 查 patches/ 里每个补丁在**上游**是什么状态：修了没有、该不该往上游提。
#
# 为什么要有这个脚本：`patches/UPSTREAM.md` 里那些结论会过期 —— 上游随时可能
# 把某处修掉，那时我们该做的是**删补丁 + 升 tag**，不是继续维护它。
# 手写的结论没人会回头复核，能跑的检查才会。
#
# 判据都是「去上游取那个文件，看特征代码在不在」，不猜、不靠 changelog。
#
# 退出码：
#   0   跟 UPSTREAM.md 记的一致
#   10  **上游状态变了** —— 有补丁可以删了，或者原本没修的修了。好消息，但要动手
#   1   查不了（网络断了之类）
set -uo pipefail
G=https://android.googlesource.com
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
AOSP_TAG=$(sed -n 's/^AOSP_TAG=//p' "$REPO/tools/build-common.sh" | head -1)

step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
chg()  { printf '  \033[33m!\033[0m %s\n' "$1"; changed=1; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; err=1; }
changed=0; err=0

# $1=仓库路径 $2=ref $3=文件 -> 内容到 stdout（取不到就空）
fetch() { timeout 90 curl -sS "$G/$1/+/$2/$3?format=TEXT" 2>/dev/null | base64 -d 2>/dev/null; }

# $1=名字 $2=仓库 $3=文件 $4=特征正则 $5=我们 tag 上**应该**有没有(yes/no) $6=main 上**应该**有没有
probe() {
  local name="$1" repo="$2" file="$3" pat="$4" want_tag="$5" want_main="$6" c n_tag n_main
  c=$(fetch "$repo" "refs/tags/$AOSP_TAG" "$file"); [ -n "$c" ] || { bad "$name：取不到 $AOSP_TAG 上的 $file"; return; }
  n_tag=$(printf '%s' "$c" | grep -cE "$pat" || true)
  c=$(fetch "$repo" "refs/heads/main" "$file");     [ -n "$c" ] || { bad "$name：取不到 main 上的 $file"; return; }
  n_main=$(printf '%s' "$c" | grep -cE "$pat" || true)
  local got_tag=no got_main=no
  [ "$n_tag"  -gt 0 ] && got_tag=yes
  [ "$n_main" -gt 0 ] && got_main=yes
  if [ "$got_tag" = "$want_tag" ] && [ "$got_main" = "$want_main" ]; then
    ok "$name：$AOSP_TAG=$got_tag main=$got_main（跟 UPSTREAM.md 一致）"
  else
    chg "$name：**变了** —— 期望 $AOSP_TAG=$want_tag main=$want_main，实际 $got_tag / $got_main
      去看 patches/UPSTREAM.md，该删补丁还是该改结论"
  fi
}

step "aapt2 0001：--选项=值"
# 上游 android-16.0.0_r1 起已支持（14/15 没有）。我们这个补丁是**回填**，
# 不该往上游提；AOSP_TAG 升过去就删掉它。
probe "aapt2 0001" platform/frameworks/base tools/aapt2/cmd/Command.cpp "== '='" no yes

step "simpleperf 0001：不写空的 meta info"
# 上游没修。这是**真上游候选**。
probe "simpleperf 0001" platform/system/extras simpleperf/record_file_writer.cpp \
  "second\.empty\(\)" no no

step "adb 0001：fdsan（我们只是缓解）"
# 上游那段 inotify 代码没动过。我们的补丁是关掉 fdsan，**不该往上游提**；
# 该做的是报 bug（根因是别处的裸 close 留下 fd 所有权标记）。
probe "adb 0001" platform/packages/modules/adb client/auth.cpp \
  "fdevent_create\(infd" yes yes

printf '\n'
[ "$err" = 1 ] && { printf '\033[31m有查不了的（网络？）\033[0m\n'; exit 1; }
[ "$changed" = 1 ] && { printf '\033[33m上游状态变了 —— 见上面标 ! 的那几行\033[0m\n'; exit 10; }
printf '\033[32m跟 patches/UPSTREAM.md 记的一致\033[0m\n'
