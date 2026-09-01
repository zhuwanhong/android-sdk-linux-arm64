#!/usr/bin/env bash
# 核对 docs/PARITY.md 和 docs/parity.json 没有走散。
#
# 这两份是**同一个承诺的两种写法**：一份给人读，一份给 CI 和脚本断言。
# 走散了比没有更糟 —— 用户照人读的那份下结论，CI 照机器读的那份放行。
#
# 查四件事：
#   1. JSON 合法，status 只能是 ok / partial / no
#   2. 每条非 no 的场景都得有 evidence（没有证据就不该标能做）
#   3. evidence 里提到的仓库内脚本必须真的存在（改名/删掉要当场报）
#   4. PARITY.md 表里 ✅ / ⚠️ / ❌ 的个数跟 JSON 对得上
set -uo pipefail
die()  { printf '\n  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MD="$REPO/docs/PARITY.md"; JS="$REPO/docs/parity.json"; MDZH="$REPO/docs/zh/PARITY.md"
[ -f "$MD" ] && [ -f "$JS" ] || die "docs/PARITY.md 或 docs/parity.json 不在"

python3 - "$MD" "$JS" <<'PY'
import json, re, sys, os
md_path, js_path = sys.argv[1], sys.argv[2]
repo = os.path.dirname(os.path.dirname(os.path.abspath(md_path)))
d = json.load(open(js_path, encoding='utf-8'))
rows = d["scenarios"]
bad = []
for r in rows:
    if r["status"] not in ("ok", "partial", "no"):
        bad.append("%s: status 不认识 %r" % (r["id"], r["status"]))
    if r["status"] != "no" and not r.get("evidence"):
        bad.append("%s: 标了 %s 却没有 evidence" % (r["id"], r["status"]))
    ev = r.get("evidence") or ""
    # 只查「看起来是仓库内路径」的那部分，别去猜别人机器上的命令
    # (?<![\w-]) 是必须的：否则 cmdline-tools/latest/... 里的 tools/ 会被当成
    # 仓库内路径，报「tools/latest/bin/apkanalyzer 不存在」。第一版就这么红过。
    for tok in re.findall(r'(?<![\w-])(?:tools|tests|docs)/[A-Za-z0-9_./-]+', ev):
        tok = tok.rstrip('.,')
        if not os.path.exists(os.path.join(repo, tok)):
            bad.append("%s: evidence 指的 %s 不存在" % (r["id"], tok))
if bad:
    print("\n".join("  ✗ " + b for b in bad)); sys.exit(1)

# **按显式标记切，不按标题切** —— 标题是中文的，英文版一改就 IndexError。
# 两个语言版本都数一遍：它们是同一份承诺的两种写法，走散了比没有更糟。
def table_of(path):
    t = open(path, encoding='utf-8').read()
    if "<!-- parity-table-start -->" not in t:
        print("  ✗ %s 里没有 <!-- parity-table-start --> 标记" % path); sys.exit(1)
    return t.split("<!-- parity-table-start -->", 1)[1].split("<!-- parity-table-end -->", 1)[0]
tbl = table_of(md_path)
cnt = {"ok": len(re.findall(r'\|\s*✅', tbl)),
       "partial": len(re.findall(r'\|\s*⚠️', tbl)),
       "no": len(re.findall(r'\|\s*❌', tbl))}
exp = {k: sum(1 for r in rows if r["status"] == k) for k in cnt}
if cnt != exp:
    print("  ✗ 对不上：docs/PARITY.md 数出来 %s，parity.json 是 %s" % (cnt, exp)); sys.exit(1)
import os
zh = os.path.join(os.path.dirname(md_path), "zh", "PARITY.md")
if os.path.exists(zh):
    tzh = table_of(zh)
    czh = {"ok": len(re.findall(r'\|\s*✅', tzh)),
           "partial": len(re.findall(r'\|\s*⚠️', tzh)),
           "no": len(re.findall(r'\|\s*❌', tzh))}
    if czh != exp:
        print("  ✗ 中英两份对不上：zh/PARITY.md %s vs parity.json %s" % (czh, exp)); sys.exit(1)
print("  ✓ %d 条场景：ok %d / partial %d / no %d；中英两份和 json 一致，evidence 指到的脚本都在"
      % (len(rows), exp["ok"], exp["partial"], exp["no"]))
PY
rc=$?
[ $rc = 0 ] || die "PARITY.md 和 parity.json 走散了（上面写着哪条）"
ok "docs/PARITY.md ↔ docs/parity.json"
