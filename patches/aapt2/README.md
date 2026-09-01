# aapt2 的补丁

打在 `build-aapt2.sh` 取下来的那棵树上（ReVanced/aapt2 的
`submodules/base`，AOSP pin 在 `platform-tools-35.0.2`）。

跟 [`patches/ndk/`](../ndk/) 一样：**改完用脚本验，别手改**。
`tools/build-aapt2.sh --fetch` 会打上并核对，重复跑不会叠加。

| 补丁 | 干什么 |
|---|---|
| `0001-flag-equals-value.patch` | 让参数解析器接受 `--选项=值`。AGP 的 optimize 步用等号形式，而上游只认空格形式 —— 报 unknown option 退出 1，**AGP 把这个失败吞了**，构建报成功、APK 里却没有资源 |
