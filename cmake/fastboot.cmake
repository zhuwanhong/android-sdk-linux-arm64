#
# fastboot 的构建目标 —— M3 里依赖最杂的一个。
#
# 照 AOSP 自己的 system/core/fastboot/Android.bp：
#   cc_defaults fastboot_host_defaults   那批 cflags 和 static_libs
#   cc_library_host_static libfastboot   13 个 .cpp + linux 变体的 usb_linux.cpp
#   cc_binary_host fastboot              main.cpp
#
# 要另取**三棵树**（都很小，稀疏 checkout）：
#   system/extras        libext4_utils（fastboot_host_defaults 的 not_windows 变体要）
#   external/avb         avb_headers
#   system/tools/mkbootimg  bootimg_headers
# 另外四个库上游 cmake/ 里没有，这里补出来：liblz4 / libdiagnose_usb / liblp /
# libext4_utils。libstorage_literals 只是头文件，在已有的 core/fs_mgr 底下。
#
# **必须在 cmake/mke2fs.cmake 之后 include**（要它的 libsparse）。
#
# 验收的边界写在 tools/build-fastboot.sh 里：没有 fastboot 模式的设备，能验的
# 只有版本、参数解析和错误路径 —— 真正的验收得插一台机器。
#

set(FB ${SRC}/core/fastboot)

set(FB_INCLUDES
    ${FB}
    ${SRC}/avb                              # avb_headers
    ${SRC}/mkbootimg/include/bootimg        # bootimg_headers 的 export_include_dirs
                                            # 就是 include/bootimg（源码里写的是 <bootimg.h>）
    ${SRC}/core/fs_mgr/libstorage_literals  # 只有头，不用编
    ${SRC}/core/fs_mgr/liblp/include
    ${SRC}/core/diagnose_usb/include
    ${SRC}/extras/ext4_utils/include
    ${SRC}/lz4/lib
    ${SRC}/core/include
    ${SRC}/core/libcutils/include
    ${SRC}/core/libutils/include
    ${SRC}/core/libsparse/include
    ${SRC}/libziparchive/include
    ${SRC}/libbase/include
    ${SRC}/logging/liblog/include
    ${SRC}/boringssl/include
    ${SRC}/fmtlib/include
    ${SRC}/googletest/googletest/include    # socket.h 里 #include <gtest/gtest_prod.h>
                                            #（fastboot_host_defaults 的 static_libs 有 libgtest_host）
    ${SRC}/soong/cc/libbuildversion/include
    )

# fastboot_host_defaults 的 cflags。-Werror 不带（见 cmake/zipalign.cmake）。
set(FB_CFLAGS -Wall -Wextra -Wunreachable-code
    -DANDROID_BASE_UNIQUE_FD_DISABLE_IMPLICIT_CONVERSION -D_FILE_OFFSET_BITS=64)

# ---------------------------------------------------------------- 四个补出来的库
# external/lz4/lib/Android.bp 的 cc_library liblz4
add_library(liblz4 STATIC
    ${SRC}/lz4/lib/lz4.c ${SRC}/lz4/lib/lz4hc.c
    ${SRC}/lz4/lib/lz4frame.c ${SRC}/lz4/lib/xxhash.c)
target_include_directories(liblz4 PUBLIC ${SRC}/lz4/lib)

# system/core/diagnose_usb/Android.bp
add_library(libdiagnose_usb STATIC ${SRC}/core/diagnose_usb/diagnose_usb.cpp)
target_include_directories(libdiagnose_usb PRIVATE ${FB_INCLUDES})

# system/core/fs_mgr/liblp/Android.bp
add_library(liblp STATIC
    ${SRC}/core/fs_mgr/liblp/builder.cpp
    ${SRC}/core/fs_mgr/liblp/super_layout_builder.cpp
    ${SRC}/core/fs_mgr/liblp/images.cpp
    ${SRC}/core/fs_mgr/liblp/partition_opener.cpp
    ${SRC}/core/fs_mgr/liblp/property_fetcher.cpp
    ${SRC}/core/fs_mgr/liblp/reader.cpp
    ${SRC}/core/fs_mgr/liblp/utility.cpp
    ${SRC}/core/fs_mgr/liblp/writer.cpp)
target_include_directories(liblp PRIVATE ${FB_INCLUDES})
target_compile_options(liblp PRIVATE -Wall)

# system/extras/ext4_utils/Android.bp
add_library(libext4_utils STATIC
    ${SRC}/extras/ext4_utils/ext4_utils.cpp
    ${SRC}/extras/ext4_utils/wipe.cpp
    ${SRC}/extras/ext4_utils/ext4_sb.cpp)
target_include_directories(libext4_utils PRIVATE ${FB_INCLUDES})
target_compile_options(libext4_utils PRIVATE -Wall -fno-strict-aliasing -D_FILE_OFFSET_BITS=64)

# ---------------------------------------------------------------- libfastboot
add_library(libfastboot STATIC
    ${FB}/bootimg_utils.cpp
    ${FB}/fastboot_driver.cpp
    ${FB}/fastboot.cpp
    ${FB}/filesystem.cpp
    ${FB}/fs.cpp
    ${FB}/socket.cpp
    ${FB}/storage.cpp
    ${FB}/super_flash_helper.cpp
    ${FB}/task.cpp
    ${FB}/tcp.cpp
    ${FB}/udp.cpp
    ${FB}/usb_linux.cpp      # target.linux 的那份
    ${FB}/util.cpp
    ${FB}/vendor_boot_img_utils.cpp
    )
target_include_directories(libfastboot PRIVATE ${FB_INCLUDES})
target_compile_options(libfastboot PRIVATE ${FB_CFLAGS})

add_executable(fastboot ${FB}/main.cpp)
target_include_directories(fastboot PRIVATE ${FB_INCLUDES})
target_compile_options(fastboot PRIVATE ${FB_CFLAGS})
target_link_libraries(fastboot
    libfastboot
    libext4_utils
    liblp
    libdiagnose_usb
    libziparchive
    libsparse            # 来自 cmake/mke2fs.cmake
    libutils
    libcutils
    libbase
    libbuildversion
    liblog
    liblz4
    fmt::fmt          # libbase 用 fmtlib，静态链要显式带上
    crypto
    c++_static
    z
    )
target_link_options(fastboot PRIVATE "-Wl,-z,max-page-size=16384")
