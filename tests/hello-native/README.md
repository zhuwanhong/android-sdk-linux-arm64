# tests/hello-native

README 第五节点名要的两个样例工程之一。**这个是唯一能验证 NDK host 工具链
真的能编 C 的路径**——另一个（`tests/hello-jvm/`）走纯 JVM，不碰 NDK，还没写。

```bash
tests/hello-native/build.sh            # 只编
tests/hello-native/build.sh --install  # 编完装到设备，并验证原生代码真被调用
tests/hello-native/build.sh --clean
```

## 它串起哪六段

| | 干什么 | 谁提供 |
|---|---|---|
| `ndk-build` | 编 `libhellonative.so` | **NDK 的 host 工具链——M1 的核心** |
| `javac` | 编 Java | 系统 JDK |
| `d8` | 转 dex | shell 脚本 + jar，跟架构无关 |
| `aapt2` | 编资源、打包 | **必须是能在本机跑的 aarch64 版** |
| `zipalign` | 对齐 | 同上 |
| `apksigner` | 签名 | shell 脚本 + jar，跟架构无关 |

SDK 自带的 `aapt2` / `zipalign` 是 x86_64 的，在 ARM64 上跑不了。脚本会**真的执行
一次**来判断可用性（「文件存在」不算数，第五节第 2 条），不行就报错并提示用
`AAPT2=` / `ZIPALIGN=` 指到能跑的那份。

## 判定标准

按第五节第 2 条，「装上了」不算通过。`--install` 会：

1. `adb install`
2. `am start` 启动 Activity
3. 从 logcat 里抓 `RESULT`，**核对原生函数的返回值和一次真实计算**（`20+22=42`）

抓不到 `RESULT` 就说明装上了但原生库没加载（多半是 `UnsatisfiedLinkError`），
数字不对就说明加载了但算错了。两种都判失败。

## 怎么让它变红

按第五节第 5 条，改一处让它必须失败，确认测试真的会红：

```bash
# 把原生返回值改错
sed -i 's/native ok/native BROKEN/' tests/hello-native/jni/hello.c
tests/hello-native/build.sh --install     # 应该在最后一步判失败
```

或者把 `AAPT2=` 指向 SDK 里那个 x86_64 的，应该在工具探测那步就停。

## 云机器上没有 USB 怎么办

产物是 ARM64 Linux 编出来的，**从哪台机器装不影响验证结论**：

- 把 `build/app.apk` 拷到有设备的机器上装
- 或者从有设备的机器 `ssh -R 5037:localhost:5037` 过来，把本地 adb server
  转发到云上，这样 `--install` 能直接用，整条验收都跑在 ARM64 机器上
