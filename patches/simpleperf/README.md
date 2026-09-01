# simpleperf 的补丁

打在 `build-simpleperf.sh` 取下来的那棵树上（`submodules/extras/simpleperf`，
AOSP pin 在 `platform-tools-35.0.2`）。

跟 [`patches/ndk/`](../ndk/) 和 [`patches/aapt2/`](../aapt2/) 一样：
**改完用脚本验，别手改**。`tools/build-simpleperf.sh --fetch` 会打上并核对，
重复跑不会叠加。

| 补丁 | 干什么 |
|---|---|
| `0001-skip-empty-meta-info.patch` | 不写空值的 meta info。读的一侧把空值判成文件损坏，而我们这份（Android 目标跑在 Linux 上）取不到 `ro.*` 属性，会写出 5 个空值 —— **录出来的 perf.data 自己读不回** |
