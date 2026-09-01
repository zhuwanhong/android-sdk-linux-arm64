#!/usr/bin/env bash
# 启用 .githooks/ 里的钩子。**每个 clone 都要跑一次**。
#
# 为什么不能自动：git 不允许 clone 时自动装钩子——不然 clone 一个仓库就等于
# 在本机执行别人的代码。这一步只能手动，没有绕过的办法。
#
#   提交前：落后于远端就拦住
#   提交后：自动推送

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

git config core.hooksPath .githooks
chmod +x .githooks/* 2>/dev/null || true   # 从 Windows 上 clone 来的可能没有可执行位

echo "钩子已启用：$(git config core.hooksPath)"
echo
for h in .githooks/*; do
  [ -f "$h" ] || continue
  printf '  %-14s %s\n' "$(basename "$h")" "$([ -x "$h" ] && echo 可执行 || echo '不可执行 ← 有问题')"
done
echo
echo "验一下（应该看到「已推送」或者「落后…被拦下」）："
echo "  git commit --allow-empty -m 'test: 钩子自检' && git log --oneline -1"
