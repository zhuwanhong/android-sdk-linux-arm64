#!/usr/bin/env bash
# 把每个 build-<工具>.sh 的验收段跑一遍，**只看退出码**。
#
# 为什么单独有这么一条：这个仓库的立身规矩是「退出码就是契约 —— 0 才叫验证
# 通过」，而 2026-09-02 发现 tools/build-fastboot.sh **打着「可以用了」的横幅、
# 退出码 1**。根因在 build-common.sh 的 common_verify_done()：最后一句
# `[ -n "$1" ] && echo "$1"` 在参数为空时求值为假，函数就返回 1，而它又是各
# 脚本的最后一条命令。传空参数的有 fastboot / simpleperf，以及 aapt2、dexdump、
# split-select 的部分分支。
#
# 这个 bug 藏了很久，因为单独跑脚本时人只看输出不看 $?。是 CI 里那句
# `tools/build-$t.sh || exit 1` 把它照出来的 —— 而那一轮要 70 分钟。
#
# **静态检查试过，做不到**：真正咬人的那次条件式藏在 if 分支里（函数最后一行
# 是 `fi`），判据放宽之后又开始误报 for 循环体里的正常写法。「函数返回前最后
# 执行的是哪条语句」需要真的控制流分析，不是 grep 能干的。所以这里就是跑一遍。
#
# 用法：
#   tools/check-exit-codes.sh              # 全部
#   tools/check-exit-codes.sh adb fastboot # 只查这几个
#
# 退出码：0 全部为 0 / 1 有脚本成功却返回非零 / 2 前置条件不够，没验成
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); cd "$REPO"
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
skip() { printf '\n  \033[33m?\033[0m %s\n' "$1" >&2; exit 2; }

WORK="${WORK:-$REPO/work}"
[ -d "$WORK/out" ] || skip "$WORK/out 不在 —— 这条要先把工具编出来（它只跑验收段，不编译）。"

ALL="aapt2 aapt aidl dexdump split-select zipalign adb etc1tool fastboot
     hprof-conv make_f2fs make_f2fs_casefold mke2fs sqlite3"
TOOLS="${*:-$ALL}"

step "跑各脚本的 --verify，只看退出码"
fail=0; n=0
for t in $TOOLS; do
  [ -x "tools/build-$t.sh" ] || { bad "tools/build-$t.sh 不在"; fail=1; continue; }
  out=$(timeout 600 "tools/build-$t.sh" --verify 2>&1); rc=$?
  n=$((n+1))
  # 末尾那条 ✓/✗ 拿来对照：**「打印成功」和「退出 0」是两件事**，这条检查
  # 存在的意义正是它们可能不一致。
  last=$(printf '%s' "$out" | grep -aE '✓|✗' | tail -1 | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-52)
  if [ "$rc" = 0 ]; then
    ok "$(printf '%-20s rc=0  %s' "$t" "$last")"
  else
    bad "$(printf '%-20s rc=%-3s %s' "$t" "$rc" "$last")"
    printf '        最后 5 行：\n%s\n' "$(printf '%s' "$out" | tail -5 | sed 's/^/          /')"
    fail=1
  fi
done

printf '\n'
if [ "$fail" = 0 ]; then printf '\033[32m%s 个脚本，成功时都真的退出 0\033[0m\n' "$n"; exit 0; fi
printf '\033[31m有脚本打印了成功却返回非零 —— 退出码是契约，这不能放过\033[0m\n'; exit 1
