# 踩过的坑（中文原文）

这个仓库最难复制的部分不是构建脚本，是这些**实测踩出来的教训**。
英文精简版在 [../LESSONS.md](../LESSONS.md)；这份是原文，细节更全。

工作流方面的规矩（钩子、加东西的规矩、验收入口）见
[../../CONTRIBUTING.md](../../CONTRIBUTING.md)。

## 当前状态

**当前状态**（2026-08-28）：M1–M4 都到了验收标准。SDK 包和 NDK 包都出过、
都在真 ARM64 机器上验过，`main` 上是完整仓库。

**下一步在 [README](README.md) 第三节末尾的路线图**，第一条是发 Release
（不是技术活，但在它之前后面每一条做完都等于没做）。

**还没在真机上验过的，集中在这里**——这些都写了代码、做了同构验证或变异测试，
但缺真机／真设备那一步。第一件事可以是把它们验掉：

| 没验的 | 在哪 | 怎么验 |
|---|---|---|
| **（空）** | | |

**2026-08-29：这张表清零了。** 最后一行是「`lldb` 连设备调试」，当天在一台
vivo V2337A（Android 16 / SDK 36 / arm64-v8a）上验掉：`tools/verify-lldb-device.sh`
把 NDK 的 `lldb-server` 推到设备、`adb forward`、host lldb 隔着 adb 连上去，
**停住、读了 pc（0x2e1c00）、继续到正常退出**，连跑三次都过、pc 一致。
同一台设备上 `tests/hello-native/build.sh --install` 也跑通了，logcat 里
`RESULT native ok: 64-bit … 20+22=42` —— 「装到真机」那条一并销掉。

**别把这张表当待办清单**——它是「已知的不确定」。每验掉一条，就把对应位置的
「没验」改成实测数字，并把这一行删掉。**表空了不等于以后不会再有**：
下次遇到「写了但没条件验」的东西，照样加进来，验掉再删。

## 两个人填的常量之间没有桥

`build-llvm.sh` 里有两个人工常量：`LLVM_PIN`（源码的确切提交）和
`NDK_CLANG_REV`（盖在编译器版本串里的「based on rXXXXXXx」）。**两条都各自有检查**
—— clone 到的 HEAD 必须等于 pin；NDK 自报的 clang 必须等于 `NDK_CLANG_VER/REV`。
**但它们之间没有交叉验证**：谁改了一个忘了改另一个，编出来的 clang 会盖上一个
它并不对应的戳，而所有检查照样绿。

补法是找一条能把两边接起来的事实：NDK 自带的 `clang_source_info.md` 第一行写着
它那份 clang 的上游基点（`Base revision: <40 位 sha>`），而 Google 那条
`llvm-rXXXXXX` 分支的头一个提交就是「Merge <基点> for LLVM update to XXXXXX」。
所以拿基点去我们 HEAD 的提交信息里找 —— 找得到，就说明编的源码正是这份 NDK
那份 clang 的基点。

两个细节值得记：

- **按前缀比，别按全长。** 那条合并提交信息里写的是**短 sha**（`3c92011b60`），
  拿 40 位全长去 grep 一定找不到 —— 第一版就是这么误报的，还差点让我以为
  真出了问题。
- **浅克隆没有历史**，所以不能用 `merge-base --is-ancestor`。查提交信息是
  `--depth 1` 下能做的最强的一条，而且它正好会在「分支被 respin、tip 换成别的
  cherry-pick」时变红 —— 那正是要防的情况。

变异测试：把 NDK 的 `clang_source_info.md` 里的基点改成一串 deadbeef，
检查当场红、退出码 1；改回来就绿。

## 同一条教训写了两遍，第三次照犯 —— 那就别再靠写

`cmd | grep -q PAT` 在 `set -o pipefail` 下是**竞态**：`grep -q` 一命中就退出，
上游收到 SIGPIPE，整条管道判成失败 —— **命中反而报错**。

这条在这张表里已经有两条（`llvm-nm` 那次、轮询 `/proc/net/tcp` 那次）。
2026-08-31 第三次犯：`tests/hello-native/build.sh` 里

```bash
unzip -l "$OUT/app.apk" | grep -q "lib/arm64-v8a/libhellonative.so" || die "APK 里没有原生库"
```

**APK 里明明有那个 .so，检查却报没有**。它今天跑了十几次都没事 —— 因为是竞态，
取决于 unzip 有没有来得及写完。偏偏在验 r28 那次咬人，差点让我以为 r28 编出来的
东西有问题。

所以这次不只是修那一处：

1. 全仓库扫，**改掉 13 处**；
2. 中途发现自己第一版「修法」`printf '%s' "$var" | grep -q` **仍然是管道**，
   只是数据小时不容易触发 —— 又改了一轮，换成 `case "$var" in *pat*)` 或
   herestring `grep -q pat <<<"$var"`（herestring 不构成管道）；
3. **把它变成机器守卫**：`tools/ci-checks.sh` 新增一步，`pipefail` 脚本里出现
   「管道 + grep -q」就红。变异测试过。守卫自己还误报了一次 —— 把 `|| grep -q 文件`
   里的**逻辑或**当成了管道，正则改成 `[^|]\| *grep -q` 才对。

**教训写下来还会犯；写成检查才不会。**

## 只有自己能算出来的校验和，不是验证

2026-09-01：修完评审提的问题后重跑了一次 `make-dist.sh`，新包的 sha256 跟
`docs/RELEASE-NOTES.md` 里**已经公布的那个**对不上。解开逐文件比，差别只有
`PROVENANCE.txt` 里一行生成时间 —— 二进制一模一样。

但「二进制一模一样」这句话，当时**只有我自己能确认**（解开来 diff）。外面拿到
包的人只能看到两个不同的 sha256。那就等于发布页上那串数字什么也没证明。

不可复现的来源有四个，实测确认过哪几个真承重：

| 来源 | 承重吗 |
|---|---|
| 文件内容里的时间戳（PROVENANCE.txt） | **是** |
| tar 记的 mtime | **是**（换成每次取当前时间，检查立刻红） |
| tar 里的文件顺序（readdir 顺序） | **是**，`--sort=name` 钉住 |
| uid/gid/用户名 | 是（换台机器打就不同），`--owner=0 --group=0 --numeric-owner` |
| gzip 头里的时间戳 | **不承重**：压 stdin 时 gzip 没有文件名和 mtime 可写，头里本来就是 0。`-n` 留着是防「哪天改成直接压文件」。 |

时间基准取 `SOURCE_DATE_EPOCH`，没设就用 HEAD 的提交时间 —— 于是「同一个 commit
+ 同样的产物」打出来的包是固定的。

**验收方式只有一种：打两次，比 sha256**（`tools/check-reproducible.sh`，两次之间
把目录整个删掉重建 —— 只重打 tar 是验不出顺序那一项的）。光看代码里写了
`--sort=name` 不算数：我第一版变异测试挑的是 `gzip -n`，摘掉之后两次仍然一致，
说明那一项根本没承重，**变异测试选错了对象，等于没测**。

**声明的边界要写清楚**：可复现的是**打包**这一步。LLVM 那种编译产物本身是否
逐字节可复现是另一件事，没有声称。

## 归一化 tar 只解决了一半：另一半藏在文件内容里

把打包换成 `--sort=name --mtime=… --owner=0` 之后，SDK 包两次打出来一致，我当时
以为这事完了。NDK 包不是：两次 sha256 不同，diff 出来全是自带 python 的 `.pyc`。

`.pyc` 有两处不确定性，都是逐字节比出来的，不是猜的：

| 位置 | 原因 | 怎么发现的 |
|---|---|---|
| 第 9 字节 | 默认失效判据是「源文件 mtime + 大小」（PEP 552 之前的老办法） | 同一个源文件、两个不同 mtime，编出来在第 9 字节分叉 |
| 第 222 字节 | `.pyc` 里嵌着编译时的**绝对路径** | 换成 `--invalidation-mode unchecked-hash` 之后仍不一致，改在第 222 字节 |

修法是 `compileall --invalidation-mode unchecked-hash -d <固定路径>` 重编一遍
（不整个删掉 —— 官方 NDK 里也带 46 个 .pyc）。

而且这些 `.pyc` **不是从供体拷进来的，是我们自己的验证步骤跑那个 python 时顺手
生成的**。也就是说：**验证行为本身改变了被验证的产物**。

同一天还踩到同类的第二处：`build-hermesc.sh` 的 PROVENANCE 里写着
`date -u '+%Y-%m-%d %H:%M UTC'`。分钟精度意味着**同一分钟内重打看着是一致的** ——
我连着跑三次都一致，差点判它可复现，是回头比更早那一次才露的馅。
**采样间隔小于变化周期的测量，等于没测量。**

## 检查用的工具本身不在，会让检查变成绿灯

2026-09-01 外部评审指出 `tools/make-dist.sh` 把 `file(1)` 当成了隐性依赖。
那两道验收（「包里不许有 host 位置的 x86 二进制」「host 二进制真能跑」）都是这个形状：

```bash
case "$(file -b "$f")" in *ELF*) ;; *) continue ;; esac
```

`file` 不在的话命令替换是空串，每个文件都 `continue`，**两道验收双双空转**，
打印的是「host 位置上的 ELF 全是 ARM aarch64」。

先造出来再修：往包里塞一个真的 x86-64 二进制，把这段逐字搬进**没有 `file` 的
`ubuntu:22.04`**（原始镜像确实没有 `file`，我们自己的构建镜像装了）里跑 ——
报绿。评审说的是真的。

修的时候发现问题比评审说的大一圈：

1. **不止 make-dist.sh** —— 全仓 14 个文件在用 `file`，`make-ndk-dist.sh` 那几处
   还带 `2>/dev/null`，连 `command not found` 那点线索都没有。
2. **零覆盖本身就该是红的**。同一次排查里，把 `WORK` 指到不存在的目录，
   打出来的是 `✓ 0 个 host 二进制真跑过一遍，都能起来` —— 这次 `file` 是在的。
   所以只补 `command -v file` 不够：`n_elf`/`n_ran` 为 0 也得死。
   （`make-ndk-dist.sh` 早就有这三条断言：`n_host >= 40`、`n_ran >= 10`、
   静态库那条的「一个都没查到 ≠ 查过都对」。落后的是 SDK 那个打包器。）
3. **变成机器守卫**：`ci-checks.sh` 新增一步 —— 用 `file` 判架构的脚本必须先
   `command -v file`，否则红。这条守卫一上线就抓到 `build-hermesc.sh`（不用造样本）。

**「无法验证」跟「通过」必须分开**，这是这个仓库的立身规矩（退出码 2 那条）。
一个工具没装就能把它们焊在一起，说明规矩当时只写在 README 里，没写进代码。

## 钉「分支 tip」只在上游没往前走时成立

`build-llvm.sh` 从 Google 的 `llvm-rXXXXXX` 分支 `--depth 1` 克隆，也就是编
**当时的 tip**。r27 那次编出来正好是 18.0.2、跟 NDK 声明的一致 —— 我一度以为
这说明做法是对的。r28 上就露馅了：NDK r28c 声明 19.0.1，而分支 tip 已经走到
19.0.2。**r27 的严丝合缝是运气，不是设计。**

处理办法不是假装没差（默默放行），也不是硬追同一性（去二分找 19.0.1 那个点 ——
而字母 `e` 是 Google 内部 respin 标记，公开分支上根本没有对应点，追不到确证）。
而是：**显式放行 + 把偏差的后果实测出来**（资源目录按大版本命名所以对得上、
两条构建路径都能编、APK 在真机上跑通、设备上那份跟本地 sha256 一致），
再把偏差写进文档和包的出处说明。

## 黄金值是跟版本绑死的

`build-llvm.sh` 3/6 那段「驱动行为逐 token 比」的黄金值是照 clang 18.0.2 录的。
clang 19 展开 AArch64 target-feature 的方式变了（多一个 `+fp-armv8`，顺序也不同），
拿 18 的黄金值比 19 **必红，而那是版本差异不是缺陷**。

录一份新的需要**能执行官方 x86_64 clang 的机器**（这台跑不了，qemu 已卸也不该
为此装回来）。所以那一步改成：版本对不上时**明说「没验」**，而不是判失败。
**没测不等于坏了，也不等于没事** —— 这是第三种状态，得有第三种说法。

## 该跟哪几个 NDK 版本（2026-08-31 查的）

Google 发着 **67 个 NDK 版本**，追不过来。但绝大多数工程**不写 `ndkVersion`**，
用的是框架或 AGP 钉的默认值 —— 那个是查得到的：

| 谁 | 钉的 NDK | 怎么查的 |
|---|---|---|
| React Native | **27.1.12297006** | `node_modules/react-native/gradle/libs.versions.toml` |
| Flutter（master） | **28.2.13676358** | `FlutterExtension.kt` 源码 |
| AGP 9.3 默认 | **28.2.13676358** | 官方 AGP 兼容性表 |
| AGP 8.0 默认 | 25.1.8937393 | AGP 8.0 发布说明 |
| Godot（master） | 29.0.14206865 | `platform/android/detect.py` |
| — | **r27 是唯一标 LTS 的** | NDK 官方修订历史 |

我们编的是 **27.1.12297006** —— LTS，也是 React Native 那一支。

**实测过一件用户一定会撞上的事**：把测试工程里的 `ndkVersion` 去掉之后，
AGP 9.3.2 **一声不响地下载并安装了 NDK 28.2.13676358**（2.2 GB），
而它只有 `linux-x86_64`，clang 在 ARM64 上根本 exec 不了。所以文档里那句
「每个带原生代码的模块都要钉 ndkVersion」不是建议，是必须。

**与其追版本，不如让换版本变便宜**：`tools/build-ndk-version.sh` 去读目标 NDK 的
`AndroidVersion.txt`（里面就写着 clang 版本和 `based on rXXXXXX<字母>`），
据此推出 LLVM 分支名，**并去上游确认那个分支真的存在**再往下走。
拿已知答案的 27.1 校准过：推出来的三个值跟写死的默认值一字不差。

## 先跑这一条

```bash
tools/ci-checks.sh      # 快检查：语法、CRLF、可执行位、两份 parity 一致、链接、项目前提
```

十几秒，不编译不下树。它绿了不代表东西能用（那要 `tests/`），但它红了就别往下走。

## 硬性：Git 工作流

**改之前先 pull，改完立刻 push。** 没有例外。

```bash
git pull --rebase --autostash     # 动手之前
# ... 改 ...
git commit -m "..."               # 提交后会自动推送
```

这条规矩由 `.githooks/` 里的钩子机械执行，不靠谁记得：

| 钩子 | 干什么 |
|---|---|
| `pre-commit` | fetch 一下，本地落后于远端就**拦下提交**并告诉你跑什么命令。离线时放行。 |
| `post-commit` | 自动 `git push`。推送失败不会让提交失败，但会把原因和收拾办法打出来。 |

**每个新 clone 都要跑一次**（git 不允许 clone 时自动装钩子——那等于 clone
就执行别人的代码）：

```bash
tools/setup-hooks.sh
```

没跑这一步，上面两条就不生效，只能靠自觉。**新 clone 的第一件事就是跑它。**

临时绕过：`git commit --no-verify`。

**为什么 pre-commit 不干脆自动 pull**：它跑的时候要提交的改动已经在暂存区里了，
这时做 `pull --rebase --autostash` 会把暂存区连根端走，rebase 完只放回工作区——
暂存状态没了，紧接着那次 commit 没东西可提交，**会凭空消失**。实测过，不是推测。
「动手前先 pull」只能在动手前做。

## 这个项目在干什么

把 Android SDK / NDK 移植到 ARM64 Linux。背景、事实核验、里程碑全在
[README.md](README.md)，**动手前先读第五节「验证纪律」**——那一节比技术方案重要。

一句话版本：所有事实都必须能一条命令重跑（`tools/verify-claims.sh`），
所有产物都必须在**真 ARM64 机器**上验过才算数。在 x86 上「编过了」什么都不证明。

## 在 Windows 上改这个仓库要小心三件事

都已经踩过，别再踩：

1. **换行符** —— `core.autocrlf=true` 会把脚本换成 CRLF，到 Linux 上就是
   `bad interpreter: /usr/bin/env bash^M`。`.gitattributes` 已经把
   `*.sh` / `*.py` / `*.cmake` / `*.patch` / `.githooks/*` 钉成 LF。**新加别的
   可执行文件类型，记得往里加一条。**

2. **可执行位** —— Windows 上 `core.filemode=false`，`chmod +x` 会被 git 无视，
   文件以 `100644` 提交，Linux 上就是 `Permission denied`。`.gitattributes`
   管不了权限位。加新脚本之后必须：

   ```bash
   git update-index --chmod=+x path/to/script.sh
   git ls-files -s tools/ .githooks/    # 确认是 100755
   ```

3. **补丁的上下文** —— `patches/ndk/` 里的补丁是照 NDK r27.1 生成的，上下文行
   必须是 LF。改补丁之后用 `tools/patch-ndk.sh --check` 验，别手改。

4. **别改正在跑的脚本。** bash 是**边读边执行**的：一个跑了两小时的
   `tools/build-*.sh`，你中途改它，它接着往下读的是改完的新字节，
   偏移对不上就会在末尾冒出莫名其妙的语法错，或者把某一段执行两遍。
   这个会话里踩过两次，第二次是 `tools/build-llvm.sh` 编到一半时改它，
   结果日志末尾出现 `line 300: syntax error near unexpected token 'fi'`
   —— 而那时候脚本本身 `bash -n` 是通过的。
   **产物没坏，坏的是那一遍的日志和退出码，也就是你判断结果的依据。**
   要改就等它跑完，或者先 `cp` 一份出来改。
   同理，`git pull` 之前先看一眼要拉的提交动没动正在跑的那个脚本。

## 范围：不是「够打包就行」

这个项目要补的是 **Google 不发的那套 ARM64 SDK/NDK**，对标的是官方 x86_64 包的
完整度。**打包 APK 是最核心的用例、也是 M1 的验收标准，但不是全部范围。**

这条要单独写出来，是因为踩过一次：给 13 个工具按用途分表时，最后一列写成了
「打包 APK 要吗」，于是 `adb`、`sqlite3`、`mke2fs` 那些全成了「不要」——
再往下一步就是「那能不能砍掉」。判据错了：**该问「官方那个包里有没有」，
不是「打包用不用得上」。**

同一个错误还波及了 `sqlite3` 缺 ICU 那段的措辞，当时写的是「不是待办事项」。
正确的说法是「**不阻塞打包，但仍然是待办，只是优先级低**」。

按用途分表是有用的（判缺口的轻重、排优先级），但它分的是**「缺了影响谁」，
不是「要不要」**。

**反过来也有一条：「官方包里有」不等于「我们必须编」。** 判据得再往下问一层——
**这东西是 Google 独有的，还是标准开源工具？**

| | 例子 | 怎么办 |
|---|---|---|
| Google 独有，没有替代品 | `aapt2`、`adb`、`fastboot`、NDK 工具链 | 只能我们编 |
| 标准开源工具，发行版有 ARM 版 | `cmake`、`ninja` | 先验系统的能不能用 |
| 纯 Java / 跟架构无关 | `cmdline-tools`、`platforms/` | 官方那份直接能用 |

这条踩过两次：先是 `cmake` 被列成「下一个该做的真空白」（`apt install cmake
ninja-build` 一条命令就有），修正并把判据写进这份文档之后，`lldb` 又照样被归进
「只能我们编」——而 `apt install lldb` 同样一条命令，**而且设备端的
`lldb-server` 本来就在包里**（它是 Android 目标二进制，跟 host 架构无关）。
**规矩写下来了，下一条结论照样是张口就来的。**

后来把剩下的逐个查了一遍，「只能我们编」那一栏收缩到只剩 `simpleperf`：
`cmake` / `ninja` / `lldb` / `clang-tidy` / `clangd` / `glslc` / `spirv-*`
在 Ubuntu 的 arm64 源里全都有。

查的时候还差点栽第三次：本机 `apt-cache show glslc` 报 `Architecture: amd64`，
**那是这台 x86_64 机器的索引**，不能推断 arm64 源里没有——得去 Ubuntu 官方
包库看架构列表。**「拿本机查出来的结论套目标架构」正是这个项目要防的那件事，
查自己的路线图时照样会踩。**

所以：**下结论前问一句「这条我查了吗」，以及「我查的是本机还是目标」。**

**这条判据也该往回用一次：已经编出来的，有没有其实不用编的？** 回溯查了一遍
（每个工具的源码来自哪棵树、链了哪些 Android 特有的库），有一个：**`sqlite3`**
——它是唯一一个一个 Android 库都没链的。装一份发行版的跑同样的判据，
**行为一模一样，而且它多了 FTS5／RTREE、版本更新**。

顺带纠正了一个记错的缺口：「我们的 sqlite3 缺 ICU」记成了自己的缺陷，
其实发行版那份**也没有** —— 带 ICU 的是 Google 特意加的。**「跟官方不一样」
和「比标准少了什么」是两回事，别混。**

判据因此细化成四类，第二类是新加的：

| | 例子 |
|---|---|
| AOSP／Google 独有 | `aapt2` `adb` `aidl` `dexdump` NDK 工具链 |
| **上游项目 + AOSP 特有封装** | `mke2fs` `make_f2fs`（链 `libsparse`） |
| 标准开源，发行版有 ARM 版 | `cmake` `ninja` `lldb` `clangd` `glslc` |
| **上游开源，但上游只发那三个平台的二进制** | **`hermesc`**（npm 的 `hermes-compiler` 只有 win64 / osx / linux64-x86_64，没有 ARM Linux）。判据跟第一类一样是「只能我们编」，但**原因不同**：不是私有，是上游没为这个架构出包。发现这一类之前，这张表会把它错分进「标准开源，发行版有 ARM 版」—— `apt` 里根本没有它 |
| **闭源，只发那几个平台** | **`extras;google;auto`（DHU）**、多半还有 `skiaparser` —— 没有源码，**编无可编**。判据到这一格就该停手：能做的只有记清楚缺口、指出替代品。注意它跟第一格的区别：`aapt2` / `adb` 那些是 **AOSP 开源**的，所以「只能我们编」是**能编**；这一格是**不能编** |
| 纯 Java／跟架构无关 | `cmdline-tools` `platforms/` |

## 加东西的规矩

来自 README 第五节第 5 条：**每加一个工具，就加一条能在它坏掉时失败的测试。
写完先把修复摘掉跑一遍，确认它真的会红——不会红的测试没有价值。**

**还有一条同样重要：别让「测不了」和「测过了」变成同一个结果。**
这个仓库里已经踩了三次，形状每次都一样：

| 写法 | 出的事 |
|---|---|
| `[ -x "$aapt2" ]` 就当它能跑 | SDK 里那个是 x86_64，文件在、有可执行位、`exec` 是 126，输出为空，于是被判成「两个实现对不上」。修法是 `tests/common.sh` 的 `runs()`：真跑一次，看退出码 |
| 反证时假 `PATH` 里漏了 `install` | 摘掉补丁那一遍是因为 `Error 127` 挂的，不是因为要验的那件事。**反证挂了，先确认是不是挂在你想验的那件事上** |
| `readelf -n $SO \| grep -qi build \|\| echo "没有 build-id"` | 文件根本不存在时 `grep` 也失败，于是印出「没有 build-id —— 一致了」。三种结果（文件不在 / 有 / 没有）必须分开判 |
| `strings -a $BIN \| grep -q X`，脚本开头有 `set -o pipefail` | `grep -q` 一命中就退出，`strings` 收到 SIGPIPE 挂掉，`pipefail` 把整条管道判成失败 —— **命中反而报失败**。改成直接 `grep -a` 文件，不走管道 |
| 用 `ar` 判静态库架构，机器上没装 `ar` | 整个检查被跳过，脚本照样打包成功。`make-ndk-dist.sh` 改成明说「**这台没有 ar(1)，host 位置上的 .a 一个都没查**」——没查就是没查，不是查过了 |
| `ok "$na 个 host 静态库，架构都对"`，而 `$na` 是 0 | 「一个都没查到」印出来跟「查过都对」长得一模一样。判零和判过必须分开说 |
| 给验证工具加个「让它更纯粹」的参数 | `clang-tidy --checks=-*` 本意是「关掉检查、只验解析」，实际它报 `Error: no checks enabled.` 打印 usage 直接退出 —— **文件根本没编译**。而 usage 里是大写 `Error`，判据 grep 的是 clang 诊断格式的小写 `error:`，两个巧合叠起来，整步验证变成 no-op 却报绿。**为了「验得更干净」而加的参数，把验证本身关掉了。** |
| `command -v docker` 过了就开跑 | 客户端装着、守护进程没跑 —— 每个镜像安静地印一片「（没走到）」，看着像跑过了。要查 `docker info`。**「工具在」不等于「工具能用」，跟 aapt2 那次是同一个形状** |
| 改了个「看着是说明文字」的字段 | `make-ndk-dist.sh` 把出处写进 NDK `source.properties` 的 `Pkg.Desc`。而 NDK 自己的 `android-legacy.toolchain.cmake` 用 `"^Pkg\\.Desc = Android NDK\nPkg\\.Revision = …"` 读版本号——**要求头两行一字不差**。多写几个字，**所有走 CMake 的 Gradle 工程全挂**。八道检查全绿、真机出过 APK、端到端过了，一道都没碰到，因为它们走的都是 ndk-build，而 ndk-build 不读这个文件。**跟丢 `prebuilt/` 那次同形：改完/删完，没人查谁还在解析它** |
| 拿「构建成功」当产物合格 | AGP 调 `aapt2 optimize … --resource-path-shortening-map=<路径>`，我们的 aapt2 只认空格形式，报 unknown option 退出 1 —— **AGP 把这个失败吞了**，照报 `BUILD SUCCESSFUL`，而 APK 里 `AndroidManifest.xml` 和 `resources.arsc` **全没了**。`tests/gradle-build.sh` 因此逐项拆 APK 验，不看退出码 |
| 探路脚本把 stderr 收进同一个变量 | 查「这 5 个 AOSP 仓库有没有 `platform-tools-35.0.2` 这个 tag」，写成 `out=$(git ls-remote … 2>&1)`，然后拿 `[ -n "$out" ]` 判有没有 —— **仓库根本不存在时的报错也是非空**，于是 `external/xz`（不存在）被判成「有」，直到 clone 才炸。改成看退出码 + `grep refs/tags/`。**跟这张表里其他几条同形，这次是查依赖的临时脚本犯的，不是仓库里的检查** |
| 藏了退出码，把「跑不起来」读成「结果一致」 | 验 hermesc 跟官方逐字节比对时，反证那步写成 `"$OFF" … >/dev/null 2>&1` 就去 `cmp`。那一刻机器上的 qemu 刚被卸载，官方那份（x86_64）**根本没跑起来**（rc=126，没产出文件），`cmp` 拿旧文件比，我据此得出「这条检查是摆设」的结论 —— **而它其实是好的**。装回 qemu 重做，同输入逐字节一致、换输入报 15994 字节不同。**判据的前提（那个工具跑没跑起来）自己也要判。** |
| `pgrep -f` 把自己也匹配进去 | 动别人的 `$ANDROID_HOME` 之前查「有没有构建在跑」，写成 `pgrep -af 'gradlew\|bash ./build.sh'` —— **`pgrep -f` 比对的是完整命令行，而我这条命令行里就含着那个模式串**，于是它匹配到自己，报「有构建在跑」。连着两次被它骗，第二次还在打印「停手」之后照样往下走了（`&&`/`||` 不会中止）。查进程要么用不含自身特征的模式（`pgrep -af gradlew` 再 `grep -v pgrep`），要么直接看锁文件和日志的时间戳。**判据把自己算进去了，就永远为真。** |
| 拿退出码判「动态链接的程序跑没跑起来」 | `test-clean-machine.sh` 的 T1 写 `rc < 126` 就算 ok —— 那对**静态**二进制成立，对动态链接的不成立：glibc 太老时 `ld.so` 打一句 ``version `GLIBC_2.38' not found`` 然后退 **1**。于是 22.04 和 debian:12 上明明起不来的 clang 被判成 ok，连最后那张结论表都印着 `T1=ok`。改成看它有没有真打出 `clang version` —— **要找「跑起来了」的直接痕迹，别指望失败会体面地退出**。这条是这张表里 aapt2「exec 是 126」那条的**另一面**：126 能抓住一类，抓不住另一类 |
| 结论写成「它不支持」，其实是我的参数不对 | 「sdkmanager 不认 `SDK_TEST_BASE_URL`（起了本地服务，一次请求都没收到）」——这条在表里挂了很久。真查下去：**它认，只是基址必须以 `/` 结尾**。`AndroidSdkHandler` 的 `REPO_URL_PATTERN` 是 `%srepository2-%d.xml`，少了斜杠拼成非法 URL，sdkmanager 打一句 `Ignoring invalid SDK_TEST_BASE_URL` 就不发请求了 —— 跟「不支持」现象一模一样。**「一个请求都没收到」能同时解释「不支持」和「我传错了」，我当时只取了前一个。** 查法也值得记：不是继续试，是去 jar 里读常量（`SDK_TEST_BASE_URL_ENV_VAR` / `sdk.test.base.url` / `android.sdk.custom.url` / `repositories.cfg` 四条机制一次看全） |
| **验收机上装了 `qemu-user-static`** | binfmt 一注册，x86_64 的二进制就在 ARM64 上「跑得起来」，而这个仓库好几条检查的判据正是「真跑一次，看退出码」（`tests/common.sh` 的 `runs()`、`make-ndk-dist.sh` 验六、`make-dist.sh` 的「真跑一遍」）。2026-08-29 实测同一个二进制两种环境：**静态链接**的 x86_64（官方 hermesc）装着 qemu 时退出码 **0** → `runs()` 判「能跑」，**假绿**；卸掉后 **126** → 判红，对。动态链接的那种两种环境都判红（qemu 找不到 x86_64 的 guest 库，报 255）。**所以危险的正是静态二进制 —— 而这个仓库自己的产物全是静态的。** `build-common.sh` 的 `ALLOW_QEMU` 开关就是为这件事留的。**验收机上别装它**；只有「拿官方 x86_64 工具做对照」这类事才需要，用完卸掉 |
| **sysroot 里有一份跟你要编的库同名的头** | 编 ICU 时满屏 `use of undeclared identifier 'Appendable'`。查到 `uconfig.h` 在 `defined(ANDROID)||defined(__ANDROID__)` 时会 include `uconfig_local.h`，而 NDK 交叉编时找到的是 **NDK sysroot 里那一份**（`sysroot/usr/include/uconfig_local.h`），它写着 `U_SHOW_CPLUSPLUS_API 0` —— 那是给**用**系统 ICU 的 app 的（NDK 只暴露平台 ICU 的 C API），不是给**编** ICU 的人的。自己放一份空的同名头到 `-I` 路径里盖掉就好（`-I` 比 sysroot 的系统目录先搜）。**「编这个库」和「用这个库」需要的配置是相反的，而两边共用一个头文件名。** |
| 按名字猜宏的含义 | 上一条盖掉之后又挂在 `androidicuinit/android_icu_init.h` 找不到。触发它的是裸的 `ANDROID` 宏，我下意识读成「目标平台是 Android」（那明明是 `__ANDROID__`）。去定义处看一眼，`udata.cpp` 自己写着注释：`// if using the AOSP build system, e.g. Soong`。**它的含义是「本次构建由 Soong 驱动」** —— 而 NDK 的工具链文件出于历史惯例总会加 `-DANDROID`，正好撞上。全树裸用 `ANDROID` 的只有两处，`grep` 一次就数清了。**别人源码里的宏，含义在别人那里，不在名字上。** |
| 探测手段在官方产物上成立，套到自己产物上不成立 | 想在验收里 `grep` 二进制中的 `icudt<版本>_dat` 符号名，理由是「读到它就说明 stubdata 真链进去了」——**在官方那份上试过，读得到**。写完一跑当场红：官方那个是 PIE，符号留在 `.dynsym`；**我们的是静态链接 + strip 过的，符号名根本不在里面**。改成由行为探针来证（没链上→函数不存在；链了真数据→`ucol_open` 不会失败）。**「在对照物上验证过」不等于「在自己产物上成立」，两者的形态可能根本不同。** |
| 拿 PATH 里的同名工具当「发行版对照」 | 复测「发行版的 sqlite3 有没有 ICU」，写的是 `D=$(command -v sqlite3)` —— 拿到的是 `/opt/android-sdk/platform-tools/sqlite3`，**我们自己装进去的那份**（它在 PATH 上）。于是「发行版」那一列印的是我们自己旧版本的行为。指名 `/usr/bin/sqlite3` 才发现它压根没装。**跟 `pgrep -f` 自匹配同一类：判据把自己算了进去。做对照实验，两边都要指绝对路径。** |
| **探测把只能连一次的服务用掉了** | 验 lldb 连设备：起 `lldb-server gdbserver`，然后「连一下本地端口确认通了」，再让 lldb 连。结果 lldb 拿到 `Connection shut down by remote side while waiting for reply to initial handshake packet`。**`lldb-server gdbserver` 只接受一个客户端**：我那次探测连上又立刻关闭，它就当客户端走了、自己退出，真正的 lldb 再连已经没人了。**判据本身消耗了被判对象。** 改法是把探测挪到起服务之前 —— 那时它照样能判「端口在不在本机」（要判的就是这件事），却不碰服务。凡是「一次性」的东西（单连接服务、一次性 token、`read` 一次的管道），探测前先问：**这一探会不会把它用掉？** |
| `adb forward` 的口开在哪台机器上 | 同一件事上：`adb forward tcp:5039 tcp:5039` 建好了，`adb forward --list` 里也有，可本机 `ss` 里根本没有那个口，lldb 连过去 `Connection refused`。**`adb forward` 是在「跑 adb 服务器的那台」开监听口**，而云机器走 `ssh -R 5037` 时 adb 服务器在**笔记本**上，口就开在笔记本。直连 USB 时两者同机，永远不会注意到这件事。解法是把调试端口也 `-R` 过来（所以脚本用**固定端口**，随机端口没法预先隧道）。**「命令成功了」和「东西出现在我这台上」是两回事。** |
| **验收全是「本地解析」，一次没让它真干活** | `build-adb.sh` 原来六步：版本串、不认识的参数、子命令表、二进制里嵌的 dex 字符串、连不上 server 时的报错 —— **全绿，而且全是本地解析**。2026-08-30 才发现这份 adb **根本起不了服务器**（本机 6/6 必崩），而 adb 的活就是起服务器跟设备说话。那六步一条都抓不到，因为一次都没让它真起来过。补了「起一个真的 server」那步（用非默认端口，避开 5037 上可能挂着的 ssh -R 隧道），拿补丁前那份做变异测试：前五步照样全绿，第六步红。**「能解析参数」不等于「能干活」；验收要挑那件工具存在的理由去验，不是挑容易验的。** |
| bionic 的 fdsan 把上游看不见的 bug 变成致命错误 | 上面那个崩溃的根因不在我们这边：fdsan（fd 所有权检查）是 **bionic 独有**的，官方 Linux adb 是 glibc 编的，根本没有这套检查。上游有一处 `unique_fd` 拥有的 fd 被裸 `close` 关掉、标记没清；glibc 上永远看不见，我们这份**静态 bionic** 上就是一起就 abort。`strace` 查出来：那个 fd 号先被拿去读 `~/.android/adbkey`，关掉后被 `inotify_init1` 复用，`fdevent_create` 接管时撞上残留标记。**这是这个项目的一类固有风险**：把 Android 目标二进制拿到 Linux 上跑，会激活一批上游从没在这个组合下测过的检查。遇到就先分清「是我们编错了」还是「上游的潜在问题被照出来了」—— 这次是后者，所以补丁是「让行为跟官方 glibc 那份一致」，不是「改上游的逻辑」。 |

共同点：**失败路径和成功路径共用了同一个退出码**。写检查时先问一句
「这条命令失败的时候，我分得清是哪种失败吗」。

**还有一条：红检查自己也会不红 —— 而它不红的时候，绿检查就什么都没证明。**
验「工具链里的 python3 是自足的」，第一版是这么设计的：把包里的 python3 藏起来、
PATH 里塞一个必然失败的假 python3，构建应该炸。**它没炸。** 原因就写在我们自己
`patches/ndk/0005` 的注释里 —— 假 python3 存在且可执行，`command -v python3`
找得到它，`HOST_PYTHON` 被设成它，`$(error)` 不触发；调用失败后 `$(shell)`
只返回空串，构建照样「成功」。注释是自己写的，设计测试时却忘了。

改法是**换判据，别换力度**：PATH 上放一个探针 `python3`，它记录自己被调用、
然后 `exec` 转发给真的（所以两遍都能编成功）。判据从「构建成败」变成
「**它有没有被调用**」：包里的 python3 在场时该是 0 次，藏起来时该 >0 次。
两个数都要，只有一个说明不了问题 —— 0 次也可能是「这条路径根本不调 python」。

一般化：**当「失败」这件事本身可能被吞掉，就别拿失败当判据，去找一个能直接
观察的痕迹。**

**还有一条形状不同、但一样会漏的：删完东西，没人查谁还指着它。**
`make-ndk-dist.sh` 头一版把 NDK 的 `prebuilt/` 整个丢了，而顶层的
`ndk-stack` / `ndk-gdb` / `ndk-which` / `ndk-lldb` 都**写死**转发到
`prebuilt/linux-x86_64/bin/` —— 四个入口全变成 `127 not found`，
当时六道检查一道都没抓到：它们只看 ELF 的架构和符号链接，
**没有一道是「引用还成不成立」**。第一次在真机上出包才发现。

所以：**丢掉/替换任何东西之后，扫一遍还有没有人引用它。**
扫的时候只算**会被执行的**（带可执行位的文本文件）—— 文档里提一句路径是
说明不是引用，把它算进去就会误报到谁都打不出包。这条分界同样在官方原版
NDK 上校准过：那四个被丢的路径，可执行引用只有那四个入口，文档命中的只有
`simpleperf/doc/scripts_reference.md`。

现有的验收入口：

```bash
tools/verify-claims.sh          # 事实还成不成立 + 已知阻塞点
tools/patch-ndk.sh --check      # NDK 补丁打没打上
tools/check-fetch-coverage.sh    # 每棵源码树是不是都有脚本负责取
                                # （不联网、不编译，随时能跑）
tools/build-<工具>.sh --verify   # 自己编的那个工具还对不对
                                # aapt aidl dexdump etc1tool hprof-conv
                                # aapt2 fastboot make_f2fs mke2fs
                                # split-select sqlite3 zipalign
tools/build-llvm.sh --verify    # 自己编的 host 工具链还对不对
                                # （跟上面那些不是一类，见下）
tools/make-dist.sh --check      # 分发包里会缺什么（不写文件）
tools/build-python.sh --verify  # 自己编的 python3 还对不对
tools/build-hermesc.sh --verify # React Native 打 release 包要的 hermesc
                                # （host 工具、glibc，跟 build-llvm.sh 同类，
                                #   不走 build-common.sh 那个静态 bionic 骨架）
tools/make-repo.sh              # 做本地仓库；末尾用官方 XSD 校验 XML
tools/make-ndk-dist.sh          # 把改造好的 NDK 打成包；八道检查 + 一道自检
tools/test-clean-machine.sh     # 干净机器验收：量依赖 + 裸容器实测
tools/make-downstream-sdk.sh    # 把两个 release 包铺成下游用的干净 ANDROID_HOME，
                                # 末尾把每个原生件真执行一遍。开发环境和使用环境
                                # 必须分开，理由见 README 第七节
tests/gradle-build.sh           # M1 的验收标准：两个样例工程走 AGP/Gradle
                                # 出 APK，再逐项拆开验（不看 BUILD SUCCESSFUL）
tools/link-system-tools.sh      # 把发行版已有的 cmake/ninja/lldb/clangd/glslc
                                # 接进 SDK/NDK，四组挨个真验；--check 只看
                                # --deps 那半不用 docker，x86_64 上也能跑
```

**加新工具别再复制一份骨架。** 找源码树、核对 tag、找 NDK、cmake 配置、编、
strip、取产物这些每个工具都一样的部分在 [`tools/build-common.sh`](../../tools/build-common.sh)，
用法写在它开头。尤其那组 cmake flag **必须几个工具逐字一致** —— 它们共用同一个
build 目录，配置一变就全树重编。

`tools/make-dist.sh` 也不走骨架 —— 它不编东西，只把产物摆成 `sdkmanager`
装出来的样子。它的清单**运行时从官方包读**，不写死；判「这个 ELF 该不该换」
看的是**位置**不是架构（`renderscript/lib/<abi>/` 底下的 x86 `.so` 是给 x86
设备用的目标产物，照搬才对）。

**「按位置不按架构」这条原则是通用的，可具体那份位置名单不通用 —— 换棵树就得
重新数。** `tools/make-ndk-dist.sh` 上栽过：SDK 的目标产物在 ABI 目录下
（`arm64-v8a`、`x86_64`），NDK 的在**三元组**目录下（`x86_64-linux-android`、
`arm-linux-androideabi`）。把 SDK 那个 `is_abi_path()` 照搬过去，`sysroot/`
底下一千多个目标库会被当成「host 位置上的异架构文件」，包直接打不出来。

所以搬一条判据到新地方，**先拿一棵已知答案的树校准**，别直接用在自己的产物上：
`make-ndk-dist.sh` 的名单是在**官方原版 x86_64 NDK** 上数出来的 ——
host 位置 133 个 ELF、133 个全是 x86-64（一个目标产物都没误判进来），
有 Linux INTERP 却不在名单里的 0 个（一个 host 二进制都没漏在外面）。
这两个数对得上，名单才算立住。跟 `make-repo.sh` 的 XSD 校验器先在 Google
自己那份 `repository2-3.xml` 上校准是同一个套路。

**唯一不走这个骨架的是 [`tools/build-llvm.sh`](../../tools/build-llvm.sh)**，它编的是
**host** 工具链（跑在本机上的 clang/lld），不是拿 NDK 交叉编出来的目标二进制。
骨架里那套（`android.toolchain.cmake`、`ANDROID_ABI`、验收时断言产物是 aarch64）
在它身上一条都不适用，所以它只照抄了打印函数。别把它并进骨架。

每个工具的目标定义放 `cmake/<工具>.cmake`，**依赖清单照抄该工具自己的
`Android.bp`**，不要照抄别人的 CMake（别人的可以当参考，权威是 Android.bp）。
动手第一件事是**确认源码在哪棵树里** —— zipalign 和 aidl 的源码都不在上游那
18 个子模块里，aapt 和 split-select 的在。这一步不能猜。
