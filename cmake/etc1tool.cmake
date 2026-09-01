#
# etc1tool 的构建目标。
#
# 照 AOSP 自己的 development/tools/etc1tool/Android.bp（cc_binary_host etc1tool）：
#     srcs: etc1tool.cpp
#     static_libs: libexpat libpng libETC1 libz
#
# libETC1 是 frameworks/native 里的一个模块（native/opengl/libs/Android.bp 的
# cc_library libETC1，就一个 ETC1/etc1.cpp），上游的 cmake/ 里没有，这里补出来。
# frameworks/native 本来就是那 18 个子模块之一，所以**只差 development 这一棵树**。
#
# 它干什么：PNG <-> ETC1 压缩纹理（.pkm）互转。
#

add_library(libETC1 STATIC ${SRC}/native/opengl/libs/ETC1/etc1.cpp)
target_include_directories(libETC1 PUBLIC ${SRC}/native/opengl/include)

add_executable(etc1tool ${SRC}/development/tools/etc1tool/etc1tool.cpp)
target_compile_options(etc1tool PRIVATE -Wall)   # -Werror 不带，理由见 cmake/zipalign.cmake
target_include_directories(etc1tool PRIVATE
    ${SRC}/native/opengl/include
    ${SRC}/libpng
    ${SRC}/expat/lib
    )
target_link_libraries(etc1tool
    libETC1
    png_static
    expat
    c++_static
    z
    )
target_link_options(etc1tool PRIVATE "-Wl,-z,max-page-size=16384")
