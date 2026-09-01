#
# ICU：官方那份 host sqlite3 静态链的三个库。
#
# 清单和编译选项照抄 external/icu 自己的 Android.bp：
#     Android.bp                    cc_defaults icu4c_defaults
#     icu4c/source/common/Android.bp    libicuuc_defaults   （srcs: ["*.cpp"]）
#     icu4c/source/i18n/Android.bp      libicui18n_defaults （同上）
#     icu4c/source/Android.bp           libicuuc_stubdata
#
# **按 host 那一支配，不是 android 那一支。** dist/Android.bp 里 sqlite3 的
# host 分支是 static_libs: [libicui18n, libicuuc, libicuuc_stubdata]，
# 而 android 分支用的是 shared_libs: [libandroidicu]。我们要的是前者 ——
# 产物是个自带一切的命令行工具，不是跑在设备上、能找到系统 ICU 的东西。
# 所以**不设** `-DANDROID_LINK_SHARED_ICU4C`（Android.bp 里那是 target.android
# 那一支加的，注释写「Require this flag to compile against libicuuc and libicui18n」
# —— 给**用**这两个库的人，不是给编它们的人）。
# **记一笔走过的弯路**：第一次编挂在 C++ API 全不可见时，我一度断定就是漏了这个
# 宏（「注释里写着 compile against」），差点把它加上。真正的原因是下面那段的
# uconfig_local.h。**「有个宏名字看起来对得上」不是证据**，去把预处理跑一遍才是。
#
# **数据的事，先说清楚**：这里链的是 `stubdata`，跟官方一样 —— 那是一个空的
# `icudt<版本>_dat` 符号（官方那个二进制里实测 **64 字节**）。所以编出来是
# 「有 ICU 接口、没有区域数据」，跟官方一致，**不是** 「ICU 能用了」。
# 真数据在同一棵树里（`icu4c/source/stubdata/icudt75l.dat`，27,956,384 字节），
# 以后要加是**打包或重链**的事，不用重编这两个大库。
# 版本必须配套：这棵树是 ICU **75**，数据只能用 `icudt75l.dat`。
#
# `-Werror` 不带（理由见 cmake/zipalign.cmake）。其余 -W 照抄。

set(ICU ${SRC}/icu/icu4c/source)

# ---------------------------------------------------------------- 盖掉 NDK 那份 uconfig_local.h
#
# **不盖掉就编不了。** icu4c/source/common/unicode/uconfig.h 里写着：
#     #if defined(ANDROID) || defined(__ANDROID__)
#     #define UCONFIG_USE_LOCAL 1
# 于是 ICU 会去 include "uconfig_local.h"。用 NDK 交叉编时，找到的是
# **NDK sysroot 里那一份**（.../sysroot/usr/include/uconfig_local.h），内容是
#     #define U_DISABLE_RENAMING 1
#     #define U_SHOW_CPLUSPLUS_API 0     <- 关键
#     #define U_HIDE_DRAFT_API 1 ...
# 那是给**用系统 ICU 的 app** 准备的：NDK 只暴露平台 ICU 的 C API。
# 而我们是在**编 ICU 本身** —— C++ API 一关，common/*.cpp 里满屏
# `use of undeclared identifier 'Appendable'`（第一次编就是这么挂的）。
# AOSP 的 host 构建碰不到这个文件，因为它不走 NDK sysroot。
#
# 所以放一份**空的**同名头在 -I 路径里（-I 比 sysroot 的系统目录先搜），
# 让 ICU 回到它自己的默认值 —— 那正是 AOSP host 那一支的行为。
#
# **必须对所有引 ICU 头的代码都生效**，所以下面是 PUBLIC 而不是 PRIVATE：
# 库这边关着 renaming、用的那边开着，链接期就是一片 undefined symbol。
set(ICU_SHIM ${CMAKE_CURRENT_BINARY_DIR}/icu-shim)
file(MAKE_DIRECTORY ${ICU_SHIM})
file(WRITE ${ICU_SHIM}/uconfig_local.h
"// 由 cmake/icu.cmake 生成，故意是空的。理由见那里的注释：\n"
"// 用来盖掉 NDK sysroot 里那份（它给 app 用，会关掉 ICU 的 C++ API）。\n")


# icu4c_defaults 那组，逐条抄
# -UANDROID：**不是笔误，也不是为了骗过什么。** udata.cpp:127 那行自己写着
#     #ifdef ANDROID // if using the AOSP build system, e.g. Soong,
#                    // but not the normal GNU make used by ./updateicudata.py
# 也就是说裸的 ANDROID 在 ICU 源码里的含义是**「本次构建由 Soong 驱动」**，
# 不是「目标平台是 Android」（那个是 __ANDROID__，我们照旧留着）。
# 而 NDK 的工具链文件出于历史惯例总会加 -DANDROID，于是撞了个正着：
#     fatal error: 'androidicuinit/android_icu_init.h' file not found
# 全树裸用 ANDROID 的只有两处（实测 grep）：这一处，和 uconfig.h:30 —— 后者
# 写的是 defined(ANDROID) || defined(__ANDROID__)，去掉一个照样成立，不受影响。
#
# 那要不要干脆把 libandroidicuinit 也编进来「照官方」？看过它的源码：
# android_icu_init() 一上来先查 ANDROID_DATA / ANDROID_TZDATA_ROOT /
# ANDROID_I18N_ROOT 三个环境变量，缺一个就整个不跑。我们的二进制跑在
# ARM64 **Linux** 上，这三个都没有，所以它是**空转**——为一个空转多拉一个
# 目录、多链一份 liblog，不划算。真要挂数据是走 udata_setCommonData / ICU_DATA，
# 跟这个库无关。
set(ICU_COMMON_FLAGS
    -UANDROID
    -Wno-ambiguous-reversed-operator
    -Wno-deprecated-declarations
    -Wno-unused-parameter
    -Wno-unused-const-variable
    -Wno-unneeded-internal-declaration
    -DUCONFIG_USE_ML_PHRASE_BREAKING=1
    )

# srcs 在 Android.bp 里就是 ["*.cpp"]，所以 glob 才是照抄，不是偷懒。
# 下限是**数出来的**（platform-tools-35.0.2 那棵树：common 201 / i18n 254），
# 不是拍的 —— OpenCSD 那次写「该有一百多个」当场红过。
function(icu_glob outvar dir want)
    file(GLOB _s ${ICU}/${dir}/*.cpp)
    list(LENGTH _s _n)
    if(_n LESS ${want})
        message(FATAL_ERROR "ICU ${dir} 只 glob 到 ${_n} 个 .cpp（这棵树该有 ${want} 个）"
                            " —— submodules/icu 没取全，或者上游挪了目录")
    endif()
    set(${outvar} ${_s} PARENT_SCOPE)
endfunction()

icu_glob(ICU_COMMON_SRCS common 190)
icu_glob(ICU_I18N_SRCS   i18n   240)

# ---------------------------------------------------------------- libicuuc
add_library(libicuuc STATIC ${ICU_COMMON_SRCS})
target_include_directories(libicuuc PUBLIC ${ICU_SHIM} ${ICU}/common)
target_compile_options(libicuuc PRIVATE
    ${ICU_COMMON_FLAGS}
    -D_REENTRANT -DU_COMMON_IMPLEMENTATION
    -O3 -fvisibility=hidden
    -Wno-missing-field-initializers -Wno-sign-compare
    # common/Android.bp:47 写着 rtti: true。
    # **这里原来写的是 set_target_properties(... PROPERTIES CXX_RTTI ON) —— 假的。**
    # CMake 没有 CXX_RTTI 这个属性（`cmake --help-property-list` 里只有 CXX_STANDARD），
    # 它既不报错也不做事，编译行里 -frtti / -fno-rtti 一个都没有。碰巧 clang 默认开
    # RTTI，结果是对的，但那是撞对的。**猜一个属性名比不写更糟：它看着像做了事。**
    -frtti)

# ---------------------------------------------------------------- libicui18n
add_library(libicui18n STATIC ${ICU_I18N_SRCS})
target_include_directories(libicui18n PUBLIC ${ICU_SHIM} ${ICU}/i18n PRIVATE ${ICU}/common)
target_compile_options(libicui18n PRIVATE
    ${ICU_COMMON_FLAGS}
    -D_REENTRANT -DU_I18N_IMPLEMENTATION
    -O3 -fvisibility=hidden
    -Wno-missing-field-initializers -Wno-sign-compare
    -frtti)   # i18n/Android.bp:44 的 rtti: true，同上
target_link_libraries(libicui18n libicuuc)

# ------------------------------------------------------------ libicuuc_stubdata
# 一个文件，提供空的 icudt<版本>_dat 符号。真数据在运行时用
# udata_setCommonData / ICU_DATA 喂进去（官方那个二进制里就带着这条路径）。
# 它的 Android.bp 里**没有** rtti 那行（common/i18n 才有），所以这里也不加，
# 用编译器默认 —— 照抄就是照抄，不替它决定。
add_library(libicuuc_stubdata STATIC ${ICU}/stubdata/stubdata.cpp)
target_include_directories(libicuuc_stubdata PUBLIC ${ICU_SHIM} PRIVATE ${ICU}/common)
