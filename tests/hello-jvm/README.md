# tests/hello-jvm

README 第五节要的两个样例工程之一，**不碰 NDK**。

```bash
tests/hello-jvm/build.sh            # 只编
tests/hello-jvm/build.sh --install  # 编完装到设备，核对资源真的读到了
tests/hello-jvm/build.sh --clean
```

## 为什么不是「hello-native 减掉 JNI」

两个工程压的是**不同的路径**，不是难度递进：

| | 验的 |
|---|---|
| `hello-native` | `ndk-build` 编 C，JNI 被调用并算对。界面是代码里搭的，**完全没用到 `R`** |
| `hello-jvm` | 资源那条链，尤其 **`aapt2 link` 生成 `R.java`** ——`hello-native` 一步都没走到 |

`hello-native` 的 `MainActivity` 直接 `new TextView(this)`，所以 aapt2 只干了
「打包一个 strings.xml」。而真实的 app 几乎都用 layout、id、数组、颜色，
那条路要 aapt2 生成 `R.java`、javac 编它、资源正确进 APK，少一环就崩。

这个工程用了 `R.layout` / `R.id` / `R.string` / `R.array` / `R.color` 五类，
脚本还会检查生成的 `R.java` 里这五类都在——**光有个空壳 R.java 不算数**。

它另外还断言 **APK 里不能有 `.so`**：纯 JVM 的包混进原生库，说明哪里串味了。

## 判定标准

跟 `hello-native` 一样，「装上了」不算通过。`--install` 会启动 Activity，
从 logcat 抓 `RESULT`，核对**资源真的读出来了**（`items=abc` 来自
`R.array.items`）。抓不到说明崩了，内容不对说明资源解析错了。

## 怎么让它变红

```bash
# 改掉数组内容，运行期核对会失败
sed -i 's|<item>c</item>|<item>X</item>|' tests/hello-jvm/res/values/strings.xml
tests/hello-jvm/build.sh --install     # 应该在最后一步判失败

# 或者删掉 layout 里的 id，javac 编 R.id.message 时就该炸
sed -i '/android:id="@+id\/message"/d' tests/hello-jvm/res/layout/main.xml
tests/hello-jvm/build.sh               # 应该在 javac 那步失败
```
