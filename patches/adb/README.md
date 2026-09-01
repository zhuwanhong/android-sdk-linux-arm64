# adb 的补丁

打在 `build-adb.sh` 取下来的那棵树上（`submodules/adb`，AOSP pin 在
`platform-tools-35.0.2`）。跟 [`patches/ndk/`](../ndk/)、[`patches/aapt2/`](../aapt2/)、
[`patches/simpleperf/`](../simpleperf/) 一样：**改完用脚本验，别手改**。
`tools/build-adb.sh --fetch` 会打上并核对，重复跑不会叠加。

| 补丁 | 干什么 |
|---|---|
| `0001-disable-fdsan-on-linux-host.patch` | 关掉 fdsan（只对跑在 Linux 上的 host adb）。**不关就起不了 adb 服务器** |

## 0001 的来龙去脉

`adb start-server` 在本机 **6/6 必崩**，报的是：

```
auth.cpp:391 adb_auth_inotify_init...
fdsan: failed to exchange ownership of file descriptor:
       fd 10 is owned by unique_fd 0x…, was expected to be unowned
```

**根因不在我们这边，但只有我们会撞上。** fdsan 是 bionic 独有的文件描述符
所有权检查；官方发的 Linux adb 是 **glibc** 编的，glibc 里根本没有这套东西。
我们这份是**静态 bionic**，于是上游一处潜在的 fd 所有权问题（某个 `unique_fd`
拥有的 fd 被裸 `close` 关掉、标记没清）从「看不见」变成了「一起就 abort」。

`strace` 实测（2026-08-30）：同一个 fd 号先被 `openat` 拿去读
`~/.android/adbkey`，关掉之后被 `inotify_init1` 复用，`fdevent_create` 接管时
撞上残留的所有权标记。同时另有线程在密集 `socket()/close()` 扫端口 —— 是竞态，
但在这台机器上稳定复现。

**这是缓解不是根治**：那个裸 close 还在上游代码里，我们只是让这份二进制的行为
跟官方 glibc 那份一致。想查根因就把补丁里的 `ANDROID_FDSAN_ERROR_LEVEL_DISABLED`
改成 `ANDROID_FDSAN_ERROR_LEVEL_WARN_ONCE`：能看见报警，又不会中止。

**为什么以前没发现**：`build-adb.sh` 的验收原来六步全是**本地解析**（版本串、
参数、子命令表、二进制里的字符串），**一次都没真起过服务器** —— 那是有意的，
怕在别人机器上留副作用、顶掉 ssh -R 隧道。补丁同时补上了那一步（`6/7`），
用非默认端口，既覆盖又不碰 5037。**「能解析参数」不等于「能干活」。**
