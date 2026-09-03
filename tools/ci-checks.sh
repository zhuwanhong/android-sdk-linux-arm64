#!/usr/bin/env bash
# CI 每次 push 都跑的那批**快检查**（不编译、不下大树、不要设备）。
#
# **逻辑放这儿，workflow 只当薄壳**：这样这批检查在本机就能跑、能验，
# 不是一份只有推上去才知道对不对的 YAML。
#
# 查什么：
#   1. 所有 shell 脚本语法过（bash -n）
#   2. 脚本没有 CRLF（.gitattributes 钉了 LF，但钉不住已经进库的）
#   3. 该可执行的有可执行位
#   4. 管道里没有 grep -q（这个仓库栽过三次，见 docs/zh/LESSONS.md）
#   5. docs/PARITY.md ↔ docs/parity.json 没走散
#   6. README 里的相对链接指到的文件真的在
#   7. 没有第二份 manifest 解析器（下 Google 的包只许走一个入口）
#   8. 用 file(1) 判架构的脚本，先检查过 file 在不在
#   9. 每个脚本的 step 编号自洽（1..N/N）
#  10. 打包只许走 repro_tar（发布包要可复现）
#  11. workflow 里对外渲染的字符串（name/description/summary）是英文
#  12. Gradle wrapper 的 jar 跟官方公布的 sha256 一致（要联网）
#  13. 文档里写的每个 sha256，在最新 Release 上都找得到（要联网）
#  14. tools/verify-claims.sh：这个项目的前提还成不成立（要联网）
#
# 「各 build-*.sh 成功时真的退出 0」不在这里查 —— 那要把它们跑一遍，
# 见 tools/check-exit-codes.sh。静态判据试过，做不到：真正咬人的那次，
# 条件式藏在 if 分支里（函数最后一行是 fi），而放宽判据之后又开始误报
# for 循环体里的正常写法。
#
# 这个清单跟下面的 step 一一对应；加检查记得两头都改。
#
# 退出码：0 全过 / 1 有问题
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); cd "$REPO"
# --fast：跳过要联网的最后一步（verify-claims 会去问 Google 的 manifest）。
# 钩子里用它 —— 每次提交等十几秒去查网是没人受得了的。
FAST=0; [ "${1:-}" = --fast ] && FAST=1
fail=0
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=1; }

step "1/14  shell 语法"
n=0; bad_n=0
while IFS= read -r f; do
  n=$((n+1)); bash -n "$f" 2>/dev/null || { bad "语法错：$f"; bad_n=$((bad_n+1)); }
done < <(git ls-files '*.sh' '.githooks/*' 'tests/gradlew' 2>/dev/null | grep -vE '\.(bat|jar)$')
[ "$bad_n" = 0 ] && ok "$n 个脚本语法都过"

step "2/14  没有 CRLF"
crlf=$(git ls-files -z '*.sh' '*.py' '*.cmake' '*.patch' '*.mk' '.githooks/*' 2>/dev/null |
       xargs -0 grep -lU $'\r' 2>/dev/null | head -5)
[ -z "$crlf" ] && ok "没有 CRLF" || bad "这些文件带 CRLF：$(printf '%s ' $crlf)"

step "3/14  可执行位"
noexec=""; badexec=""
for f in $(git ls-files 'tools/*.sh' 'tests/*.sh' 'tests/*/build.sh' '.githooks/*' 2>/dev/null); do
  # **判据是有没有 shebang，不是文件叫什么名字。** 被 source 的库（common.sh、
  # build-common.sh、repro.sh）开头是注释不是 #!，本来就不该有可执行位；
  # 头一版把它们也算进来，红了两条假的，于是改成按名字排除 —— 然后新加
  # tools/repro.sh 时又漏了，提交之后才红（git ls-files 看不见未跟踪文件，
  # 所以新文件在提交前一直是「查不到」）。按 shebang 判就不用维护名单了。
  case "$(head -1 "$f")" in
    '#!'*) [ -x "$f" ] || noexec="$noexec $f" ;;
    *)     [ -x "$f" ] && badexec="$badexec $f" ;;
  esac
done
[ -z "$noexec" ] || bad "有 shebang 却没有可执行位：$noexec"
[ -z "$badexec" ] || bad "没有 shebang（是被 source 的）却带着可执行位，会误导人直接跑它：$badexec"
[ -z "$noexec" ] && [ -z "$badexec" ] && ok "该可执行的都可执行，被 source 的都没有可执行位"

step "4/14  管道里的 grep -q（这个仓库栽过三次）"
# `cmd | grep -q PAT` 在 `set -o pipefail` 下是**竞态**：grep -q 一命中就退出，
# 上游收到 SIGPIPE，整条管道判成失败 —— **命中反而报错**。
# 三次实战：llvm-nm 那次、poll /proc/net/tcp 那次、2026-08-31 的
# 「APK 里明明有 .so 却报没有原生库」。教训写了两遍还是照犯，所以改成机器查。
# 安全写法：`case "$var" in *pat*)`，或者 `grep -q pat <<<"$var"`（herestring 不是管道）。
bad_pipe=""
for f in $(git ls-files 'tools/*.sh' 'tests/*.sh' 'tests/*/build.sh' 2>/dev/null); do
  grep -q 'set -.*pipefail' "$f" || continue
  # **`[^|]\|` 是必须的**：不加的话 `|| grep -q 文件` 里那个逻辑或会被当成管道
  # —— 第一版就这么误报了 make-ndk-dist.sh:79（那是 grep 读文件，不构成管道）。
  hits=$(grep -nE '[^|]\| *grep -[a-zA-Z]*q' "$f" | grep -v ':[[:space:]]*#' || true)
  [ -n "$hits" ] && bad_pipe="$bad_pipe
$f:
$(printf '%s' "$hits" | sed 's/^/      /')"
done
if [ -z "$bad_pipe" ]; then ok "没有「管道 + grep -q」"; else
  bad "这些地方是竞态（命中可能反而报错），改成 case 或 herestring：$bad_pipe"; fi

step "5/14  PARITY.md ↔ parity.json"
if tools/check-parity.sh >/dev/null 2>&1; then ok "两份一致"; else
  bad "两份走散了，细节："; tools/check-parity.sh 2>&1 | sed 's/^/      /'; fi

step "6/14  所有 .md 里的相对链接"
missing=""
# **相对链接要相对它所在的文件解析**，不是相对仓库根。头一版拿 $REPO 解，
# 于是 docs/INSTALL.md 里的 ../README.md 和 PARITY.md 全被判成指空了 —— 假红。
while IFS='|' read -r src link; do
  case "$link" in http*|\#*|mailto:*) continue ;; esac
  t="${link%%#*}"; [ -z "$t" ] && continue
  [ -e "$(dirname "$src")/$t" ] || missing="$missing $src→$t"
# 扫**全部**被跟踪的 .md，不只是 README 和 docs/：patches/*/README.md、
# tests/*/README.md 一样会指空，而且那几份正是新人最先读的。
done < <(for f in $(git ls-files '*.md'); do
           grep -oE '\]\([^)]+\)' "$f" 2>/dev/null | sed "s|.*](|$f\||; s|)$||"
         done | sort -u)
[ -z "$missing" ] && ok "链接指到的文件都在" || bad "这些链接指空了：$missing"

step "7/14  下 Google 的包只许一个入口"
# 同一段 manifest 解析原先在三个脚本里各抄了一份 —— 三份各自会长歪，而且
# 少了 host-os 过滤就会静默拿到 windows 那个 zip。收成
# tools/fetch-google-package.sh 一份之后，用这条守住。
#   make-repo.sh **写** manifest、verify-claims.sh 拿它核对声明，都不是下载，放行；
#   ci-checks.sh 自己也排除 —— 它的 pattern 里就含着那个词，不然自己咬自己
#   （grep -q 那条守卫第一次上线时栽的就是这个）。
dupes=$(git ls-files 'tools/*.sh' | grep -vE 'fetch-google-package|make-repo|verify-claims|ci-checks' |
        xargs grep -l 'remotePackage' 2>/dev/null || true)
[ -z "$dupes" ] && ok "只有 tools/fetch-google-package.sh 解 manifest" \
  || bad "这些脚本自己解了一份 manifest，改用 tools/fetch-google-package.sh：
$(printf '%s\n' "$dupes" | sed 's/^/        /')"

step "8/14  用 file(1) 判架构的脚本，必须先检查 file 在不在"
# 栽过的地方：make-dist.sh 的两道验收都拿 `case "$(file -b …)" in *ELF*)` 当闸门。
# file 不在 -> 命令替换是空串 -> 每个文件都 continue -> 两道验收双双空转，
# 打印「host 位置上的 ELF 全是 ARM aarch64」。实测：往包里塞一个真的 x86-64
# 二进制，在没有 file 的 ubuntu:22.04 里跑，报的是绿。
# 规矩：用 file 判架构的脚本，要么自己先 command -v file，要么 source 了替它检查的公共文件。
nofilechk=""
for f in $(git ls-files '*.sh'); do
  grep -q 'file -b' "$f" || continue
  grep -q 'command -v file' "$f" && continue
  grep -qE '(source|\.) .*(build-)?common\.sh' "$f" && continue
  nofilechk="$nofilechk $f"
done
[ -z "$nofilechk" ] && ok "用 file 判架构的脚本都先检查过它在不在" \
  || bad "这些脚本拿 file 判架构却没先检查它在不在（缺了会静默报绿）：$nofilechk"

step "9/14  step 编号自洽"
# build-adb.sh 出现过 1/6…4/6 之后接 5/7、6/7、7/7；我自己给 ci-checks.sh 加检查时
# 也把编号撞车过两次。纯文案，但读的人会拿它判断「是不是漏跑了一步」。
badstep=$(for f in $(git ls-files '*.sh' '.githooks/*' 2>/dev/null); do
  awk -v F="$f" '
    match($0, /step "[0-9]+\/[0-9]+/) {
      t=substr($0, RSTART+6, RLENGTH-6); split(t, a, "/");
      num[a[1]]=1; den[a[2]]=1; cnt++
    }
    END {
      if (cnt==0) exit
      nd=0; for (k in den) { nd++; d=k+0 }
      if (nd>1) { s=""; for (k in den) s=s" "k; printf "%s: 分母不一致（%s）\n", F, s; exit }
      nn=0; mx=0; for (k in num) { nn++; if (k+0>mx) mx=k+0 }
      if (nn!=d || mx!=d) printf "%s: 分母是 %d，但只有 %d 个不同编号、最大 %d\n", F, d, nn, mx
    }' "$f"
done)
[ -z "$badstep" ] && ok "每个脚本的 step 编号都是 1..N/N" \
  || bad "step 编号对不上：
$(printf '%s\n' "$badstep" | sed 's/^/        /')"

step "10/14  打包只许走 repro_tar"
# 发布包要**可复现**：同样的输入，谁在什么时候打，sha256 都一样。直接 `tar -czf`
# 做不到 —— 文件顺序跟着 readdir 走、mtime 跟着文件系统走、uid/gid 跟着打包的人走。
# 起因：改完脚本重打了一次 SDK 包，sha256 跟 docs/RELEASE-NOTES.md 里公布的对不上，
# 解开逐文件比才确认「只差一行时间戳」—— 那说明外人没法独立核对我们的包。
# 归口到 tools/repro.sh 的 repro_tar，并且用 tools/check-reproducible.sh 打两次比。
rawtar=$(grep -nE '(^|[^_[:alnum:]])tar +[^|]*-[a-zA-Z]*c' $(git ls-files '*.sh') 2>/dev/null \
         | grep -v '^tools/repro.sh:' | grep -v ':[[:space:]]*#' || true)
[ -z "$rawtar" ] && ok "没有绕开 repro_tar 直接建 tar 包的地方" \
  || bad "这些地方直接建 tar 包（不可复现），改用 tools/repro.sh 的 repro_tar：
$(printf '%s\n' "$rawtar" | sed 's/^/        /')"

# 归一化 tar 只管元数据；**写进包里的实时时间戳一样会毁掉可复现性**。
# 实测栽过：build-hermesc.sh 的 PROVENANCE 里写着
#   编译于 $(date -u '+%Y-%m-%d %H:%M UTC')
# 分钟精度 —— 同一分钟内重打看着一致，跨了分钟就变。要用 $REPRO_STAMP。
livedate=""
for f in $(git ls-files 'tools/*.sh'); do
  [ "$f" = tools/repro.sh ] && continue          # 时间基准本来就在这儿算
  grep -q 'repro_tar' "$f" || continue           # 只查会打包的
  hits=$(grep -nE '\$\(date' "$f" | grep -v ':[[:space:]]*#' || true)
  [ -n "$hits" ] && livedate="$livedate
        $f: $hits"
done
[ -z "$livedate" ] && ok "打包脚本没有把实时时间写进包里（都用 \$REPRO_STAMP）" \
  || bad "打包脚本里有实时时间，包会不可复现：$livedate"

step "11/14  workflow 里对外渲染的字符串是英文"
# 这个仓库是**故意双语**的：tools/ 和 cmake/ 的注释、docs/zh/ 都是中文，那是推理
# 发生的地方。但**在 GitHub 界面上渲染出来的字符串是对外的一面**，跟提交信息同类。
# 实测栽过：workflow_dispatch 的 input description 是中文，别人点 Run workflow
# 看到的就是一排中文表单；step 的 name 也一样，会出现在每次运行的步骤列表里。
# 查 name: / description: / 写进 job summary 的标题；YAML 里的 # 注释不查
# （那跟 tools/ 的注释同类，留中文）。
cjk=$(grep -nP '^\s*(-\s+)?(name|description):.*[\x{4e00}-\x{9fff}]' .github/workflows/*.yml 2>/dev/null || true)
cjk2=$(grep -nP 'GITHUB_STEP_SUMMARY|echo "#+ .*[\x{4e00}-\x{9fff}]' .github/workflows/*.yml 2>/dev/null \
       | grep -P '[\x{4e00}-\x{9fff}]' || true)
if [ -z "$cjk" ] && [ -z "$cjk2" ]; then
  ok "workflow 的 name/description/summary 都是英文"
else
  bad "这些会显示在 Actions 界面上，要英文：
$(printf '%s\n%s\n' "$cjk" "$cjk2" | grep -v '^$' | sed 's/^/        /')"
fi

if [ "$FAST" = 1 ]; then
  printf '\n\033[2m12/14  Gradle wrapper 的 jar、13/14  校验和、14/14  项目前提 —— --fast，跳过（都要联网）\033[0m\n'
  printf '\n'
  [ "$fail" = 0 ] && { printf '\033[32m快检查全过\033[0m（第 12、13 步没跑：要联网）\n'; exit 0; }
  printf '\033[31m有问题（上面标了 ✗ 的）\033[0m\n'; exit 1
fi

step "12/14  Gradle wrapper 的 jar 是官方那份"
# 仓库里唯一的二进制文件。gradle-wrapper.jar 是典型的供应链下毒点：
# 它会在每次 ./gradlew 时被执行，而没人会去读一个 jar。所以别人 clone 之前，
# 我们自己先对着 Gradle 官方公布的 sha256 核一遍。
WJ=tests/gradle/wrapper/gradle-wrapper.jar
WP=tests/gradle/wrapper/gradle-wrapper.properties
if [ ! -f "$WJ" ]; then
  ok "没有 wrapper jar，跳过"
else
  gver=$(sed -n 's/.*gradle-\([0-9.]*\)-bin\.zip.*/\1/p' "$WP")
  if [ -z "$gver" ]; then
    bad "$WP 里读不出 Gradle 版本号"
  else
    local_sha=$(sha256sum "$WJ" | cut -d' ' -f1)
    off_sha=$(curl -fsSL --max-time 30 "https://services.gradle.org/distributions/gradle-$gver-wrapper.jar.sha256" 2>/dev/null || true)
    if [ -z "$off_sha" ]; then
      printf '  \033[33m?\033[0m 取不到官方 sha256（离线？）—— **这条没验成**，不当通过\n'
    elif [ "$local_sha" = "$off_sha" ]; then
      ok "gradle-wrapper.jar 跟 Gradle $gver 官方公布的 sha256 一致"
    else
      bad "gradle-wrapper.jar 跟官方公布的对不上！
        本地 $local_sha
        官方 $off_sha"
    fi
  fi
fi

step "13/14  文档里的 sha256 都能在发布页上找到"
# 栽过两次，都是「文档说的和能拿到的对不上」：
#   - RELEASE-NOTES 的表留着上一次本机构建的值，而发布的是 CI 编的那批；
#   - VERSIONS.md 写着 r28 包的 sha256，可那个包**根本没挂上去**，谁也下不到。
# 后一种尤其坏：读者会拿一个永远核不上的数字去对自己下载的东西。
# 判据很简单：文档里出现的每个 64 位十六进制串，都必须在最新 Release 的正文里。
rel=$(curl -s --max-time 30 "https://api.github.com/repos/zhuwanhong/android-sdk-linux-arm64/releases/latest" 2>/dev/null || true)
case "$rel" in
  *'"body"'*)
    stale=$(printf '%s' "$rel" | python3 -c '
import json, re, subprocess, sys
body = json.load(sys.stdin).get("body") or ""
published = set(re.findall(r"`([0-9a-f]{64})`", body))
files = subprocess.run(["git","ls-files","*.md"], capture_output=True, text=True).stdout.split()
bad = []
for p in files:
    for m in re.finditer(r"`([0-9a-f]{64})`", open(p, encoding="utf-8", errors="replace").read()):
        if m.group(1) not in published:
            bad.append(f"{p}: {m.group(1)}")
print("\n".join(bad))
' 2>/dev/null || true)
    if [ -z "$stale" ]; then
      ok "文档里的 sha256 都在最新 Release 上"
    else
      bad "这些 sha256 在发布页上找不到（读者核不上）：
$(printf '%s\n' "$stale" | sed 's/^/        /')"
    fi ;;
  *)
    # **没验成，不当通过。** 还没发过 Release、或者离线，都会走到这儿。
    printf '  \033[33m?\033[0m 取不到最新 Release（还没发？离线？）—— 这条没验成\n' ;;
esac

step "14/14  项目前提还成不成立"
# **退出码 10 不是失败**：那是「Google 开始发 linux/aarch64 了」——好消息，
# 但也意味着这个项目该重新评估。CI 里要看得见，不能当红。
out=$(tools/verify-claims.sh 2>&1); rc=$?
case "$rc" in
  0)  ok "前提仍然成立" ;;
  10) printf '  \033[33m!\033[0m **Google 已经发 linux/aarch64 包了** —— 前提失效，这个项目该重新评估（好消息）\n'
      printf '%s\n' "$out" | tail -5 | sed 's/^/      /' ;;
  *)  bad "verify-claims.sh 退出码 $rc"; printf '%s\n' "$out" | tail -10 | sed 's/^/      /' ;;
esac

printf '\n'
[ "$fail" = 0 ] && { printf '\033[32m全过\033[0m\n'; exit 0; }
printf '\033[31m有问题（上面标了 ✗ 的）\033[0m\n'; exit 1
