#
# aapt（v1）的构建目标。
#
# 源码清单和依赖照抄 AOSP 自己的 frameworks/base/tools/aapt/Android.bp
# （cc_defaults aapt_defaults + cc_library_host_static libaapt + cc_binary_host aapt）。
#
# **它跟 aapt2 不是一个东西。** Gradle 早就换成 aapt2 了，v1 留着是因为 apktool
# 那类第三方工具还在调它。它也在第 1.2 节那张 ELF 清单里，所以 M2 得覆盖它。
#
# 跟 zipalign / aidl 不同的一点，很省事：**一棵新源码树都不用取。**
# frameworks/base 本来就是上游那 18 个子模块之一，aapt 的源码就在
# submodules/base/tools/aapt/ 底下躺着。
#
# libaapt 这个静态库 split-select 也要用（见 cmake/split-select.cmake），
# 所以定义在这里，那边只管链。**include 顺序上 aapt.cmake 必须在前。**
#

set(AAPT_INCLUDES
    ${SRC}/base/libs/androidfw/include
    ${SRC}/base/libs/androidfw/include_pathutils
    ${SRC}/expat/lib
    ${SRC}/fmtlib/include
    ${SRC}/libpng
    ${SRC}/libbase/include
    ${SRC}/native/include
    ${SRC}/core/libutils/include
    ${SRC}/core/libsystem/include
    ${SRC}/logging/liblog/include
    ${SRC}/soong/cc/libbuildversion/include
    ${SRC}/incremental_delivery/incfs/util/include
    ${SRC}/incremental_delivery/incfs/kernel-headers
    )

# Android.bp 的 whole_static_libs 里有 libandroidfw_pathutils（就一个 PathUtils.cpp）。
# 不用单独定义：上游的 cmake/libandroidfw.cmake 已经把 PathUtils.cpp 编进 libandroidfw，
# include_pathutils 也在它的 PUBLIC include 里。核对过，不是假定。
add_library(libaapt STATIC
    ${SRC}/base/tools/aapt/AaptAssets.cpp
    ${SRC}/base/tools/aapt/AaptConfig.cpp
    ${SRC}/base/tools/aapt/AaptUtil.cpp
    ${SRC}/base/tools/aapt/AaptXml.cpp
    ${SRC}/base/tools/aapt/ApkBuilder.cpp
    ${SRC}/base/tools/aapt/Command.cpp
    ${SRC}/base/tools/aapt/CrunchCache.cpp
    ${SRC}/base/tools/aapt/FileFinder.cpp
    ${SRC}/base/tools/aapt/Images.cpp
    ${SRC}/base/tools/aapt/Package.cpp
    ${SRC}/base/tools/aapt/pseudolocalize.cpp
    ${SRC}/base/tools/aapt/Resource.cpp
    ${SRC}/base/tools/aapt/ResourceFilter.cpp
    ${SRC}/base/tools/aapt/ResourceIdCache.cpp
    ${SRC}/base/tools/aapt/ResourceTable.cpp
    ${SRC}/base/tools/aapt/SourcePos.cpp
    ${SRC}/base/tools/aapt/StringPool.cpp
    ${SRC}/base/tools/aapt/Utils.cpp
    ${SRC}/base/tools/aapt/WorkQueue.cpp
    ${SRC}/base/tools/aapt/XMLNode.cpp
    ${SRC}/base/tools/aapt/ZipEntry.cpp
    ${SRC}/base/tools/aapt/ZipFile.cpp
    )

# STATIC_ANDROIDFW_FOR_TOOLS 是 Android.bp 明写的，少了它 androidfw 的头会按
# 「跑在设备上」那套展开。-Wno-format-y2k 也是上游给的。
target_compile_definitions(libaapt PRIVATE -DSTATIC_ANDROIDFW_FOR_TOOLS)
target_compile_options(libaapt PRIVATE -Wall -Wno-format-y2k)
target_include_directories(libaapt PUBLIC ${AAPT_INCLUDES})

add_executable(aapt ${SRC}/base/tools/aapt/Main.cpp)
target_compile_definitions(aapt PRIVATE -DSTATIC_ANDROIDFW_FOR_TOOLS)
target_compile_options(aapt PRIVATE -Wall)   # -Werror 不带，理由见 cmake/zipalign.cmake

# Android.bp 的 static_libs 只列了 9 个（libandroidfw libpng libutils liblog
# libcutils libexpat libziparchive libbase libz）加 use_version_lib（libbuildversion）。
# 下面多出来的 libselinux / libsepol / libincfs / libpackagelistparser /
# crypto / pcre2-8 / jsoncpp 是 **libandroidfw 自己的依赖** —— Soong 会自动传递，
# 静态链到 CMake 这边就得一个个写出来（上游的 cmake/aapt2.cmake 也是这么写的）。
#
# **libprocessgroup 不在这儿，是特意去掉的。** lzhiyong 那份链了它，照抄过来会
# 直接编不过：
#     libprocessgroup/cgroup_map.cpp:222: error:
#       'ACgroupController_getMaxActivationDepth' is unavailable: introduced in Android 36
# 我们按 -DANDROID_PLATFORM=android-30 编，那个符号还不存在。查 Android.bp ——
# aapt 的依赖里本来就没有 libprocessgroup，上游 cmake/aapt2.cmake 也没链它。
# **这就是「照抄 Android.bp，别照抄别人的 CMake」的现场版。**
target_link_libraries(aapt
    libaapt
    libandroidfw
    libincfs
    libutils
    libcutils
    libselinux
    libsepol
    libziparchive
    libpackagelistparser
    libbase
    libbuildversion
    liblog
    expat
    crypto
    pcre2-8
    jsoncpp_static
    png_static
    c++_static
    dl
    z
    )

target_link_options(aapt PRIVATE "-Wl,-z,max-page-size=16384")
