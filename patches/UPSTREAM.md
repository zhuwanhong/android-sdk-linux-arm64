# 这些补丁跟上游是什么关系

**每个补丁都要能回答三个问题**：上游有没有这个问题？上游修了吗？我们该不该往上游提？
答不上来的补丁，早晚会变成没人敢碰的历史遗留。

结论会过期（上游随时可能修掉某处），所以别只读这份文件 —— **跑一次**：

```bash
tools/check-upstream-patches.sh
# 0  跟这份文件记的一致
# 10 上游状态变了：有补丁可以删了，或者原本没修的修了
# 1  查不了（网络）
```

它的判据是「去上游取那个文件，看特征代码在不在」，不猜、不靠 changelog。

---

## 一览（2026-08-30 实查）

| 补丁 | 上游有这问题吗 | 上游修了吗 | 我们该怎么办 |
|---|---|---|---|
| `aapt2/0001-flag-equals-value` | 有 | **修了** | **别往上游提** —— 我们这份是回填。`AOSP_TAG` 升到 ≥ `android-16.0.0_r1` 时**删掉它** |
| `simpleperf/0001-skip-empty-meta-info` | 有 | **没修** | **真上游候选** —— 值得提，至少该报 bug |
| `adb/0001-disable-fdsan-on-linux-host` | 有（潜在） | **没修** | **别提我们这份**（它是关掉检查的缓解）。该做的是**报 bug**，附证据 |
| `ndk/0001…0005` | 不算 bug | — | 那是「让 NDK 支持 ARM64 Linux host」，**产品决策不是 bug fix**。要推先报 issue 探态度 |

## 逐条

### `aapt2/0001-flag-equals-value` —— 上游已经修了，我们是回填

AGP 会传 `--resource-path-shortening-map=<路径>`，而 `platform-tools-35.0.2` 的
`Command.cpp` 只做 `arg == flag.name` 的精确比对，等号形式一律 `unknown option`。
**而 AGP 把这个失败吞掉**：构建照报成功，APK 里却没有资源。

逐 tag 取 `tools/aapt2/cmd/Command.cpp` 查特征代码 `== '='`：

| ref | 有没有 |
|---|---|
| `android-14.0.0_r1` | 没有 |
| `android-15.0.0_r1` | 没有 |
| **`android-16.0.0_r1`** | **有** |
| `platform-tools-35.0.2`（我们钉的） | 没有 |
| `main` | 有 |

上游的写法跟我们的不完全一样（它要求 `=` 正好在 flag 名之后，还禁止等号后为空；
我们是在第一个 `=` 处切开）。**行为一致，但升 tag 之后该用上游那份，别两套并存。**

### `simpleperf/0001-skip-empty-meta-info` —— 上游没修，值得提

写的一侧把取不到值的 `ro.*` 写成空字符串，**读的一侧把空值判成文件损坏** ——
于是我们录出来的 `perf.data` 自己读不回。

`main` 上的 `record_file_writer.cpp` 跟 `platform-tools-35.0.2` 那份**一模一样**
（694 行，没有跳空值的判断），所以问题还在。

**提上游时要说清触发条件**：simpleperf 的 Android 目标二进制跑在**非 Android**
的 Linux 上（正是本项目干的事），`ro.*` 属性取不到。上游可能觉得这不在支持范围内
—— 但**「写出来的文件自己的 reader 拒收」这件事本身是 bug，跟在哪跑无关**，
这是提交说明里该摆的论点。

### `adb/0001-disable-fdsan-on-linux-host` —— 报 bug，不是提补丁

我们这份是**缓解**：关掉 bionic 的 fdsan，让行为跟官方 glibc 那份一致。
把它提上游没有意义（上游 Linux adb 是 glibc 编的，本来就没有 fdsan）。

**该做的是报 bug**，材料现成：

- 现象：`adb start-server` 在静态 bionic 构建上 100% abort，
  `fdsan: failed to exchange ownership of file descriptor: fd N is owned by unique_fd …`
- `strace` 证据：同一个 fd 号先被 `openat` 拿去读 `~/.android/adbkey`，
  关掉之后被 `inotify_init1` 复用，`fdevent_create` 接管时撞上**残留的所有权标记**
  —— 说明某处用裸 `close` 关掉了 `unique_fd` 拥有的 fd
- 上游 `main` 的 `client/auth.cpp` 那段（`inotify_init1` + `fdevent_create(infd, …)`）
  **一个字没动**，所以隐患还在
- **对上游也不是纯理论问题**：adb 客户端在 Android 上跑就是 bionic，fdsan 是开的

细节见 [`patches/adb/README.md`](adb/README.md)。

### `ndk/0001…0005` —— 那是产品决策

让 NDK 认 `linux-aarch64` 这个 host tag。这不是「修一个 bug」，是「请官方支持
ARM64 Linux」—— 而**本项目存在的前提正是他们还没支持**
（`tools/verify-claims.sh` 每次 CI 都在验这条；哪天他们支持了它会退出 10）。

真要推的话，顺序是**先报 issue 探态度，再谈补丁** ——
一上来甩五个补丁过去，多半没人接。
