#
# dexdump 的构建目标 —— M2 四个里最重的一个。
#
# 源码清单和依赖照抄 AOSP 自己的 art/dexdump/Android.bp（art_cc_binary dexdump 的
# **host 变体**）、art/libartbase/Android.bp、art/libdexfile/Android.bp、
# art/libartpalette/Android.bp、external/tinyxml2/Android.bp。
#
# 重在哪：另外三个工具最多多取一棵树，这个要**两棵**，而且要自己定义四个库目标
# （libartbase / libdexfile / libartpalette / libtinyxml2），上游的 cmake/ 里一个都没有。
#
#     platform/art             dexdump 本体 + 上面三个 art 库（稀疏 checkout，四个目录）
#     external/tinyxml2        libartbase 的 base/metrics/metrics_common.cc 直接用它
#
# tinyxml2 那条是查出来的不是猜的：ReVanced 的 18 个子模块里没有它，而
# metrics_common.cc 里 tinyxml2::XMLElement 到处都是。
#

# art 的源码要一批编译期常量，Soong 通过 art_defaults 给，源码里 grep 不到定义：
#     arch/instruction_set.h:270: error: use of undeclared identifier 'ART_STACK_OVERFLOW_GAP_x86'
# 权威出处是 art/build/art.go:94-107 —— 那里有**两组**值：
#     开了 sanitizer：arm/arm64/riscv64/x86=16384，x86_64=20480
#     普通构建：      五个全是 8192          <- 我们是这组
# 别照着「看起来更保险」的那组抄，条件写得明明白白（SanitizeDevice/SanitizeHost）。
set(ART_CFLAGS
    # art.go:134/154 —— device 和 host 的非 sanitizer 值都是 1736，不用挑
    -DART_FRAME_SIZE_LIMIT=1736
    # art.go:117 —— 无条件加的（注释里说明了为什么不再按 target 区分）
    -DART_PAGE_SIZE_AGNOSTIC=1
    # art.go:143/169 取的是 soong 的配置值，出处 build/soong/android/config.go:1274：
    #     host 0x60000000 / device 0x70000000
    # **取 host 那组** —— 我们编出来的是 Android ABI 的二进制，但用途是 host 工具，
    # 跟上面 palette_fake、frame size 是同一个判断。dexdump 根本不加载 boot image，
    # 这个值实际用不上，但常量得存在，不然 mem_map.cc 编不过。
    -DART_BASE_ADDRESS=0x60000000
    "-DART_BASE_ADDRESS_MIN_DELTA=(-0x1000000)"     # art.go:145，括号是值的一部分
    -DART_BASE_ADDRESS_MAX_DELTA=0x1000000
    -DART_STACK_OVERFLOW_GAP_arm=8192
    -DART_STACK_OVERFLOW_GAP_arm64=8192
    -DART_STACK_OVERFLOW_GAP_riscv64=8192
    -DART_STACK_OVERFLOW_GAP_x86=8192
    -DART_STACK_OVERFLOW_GAP_x86_64=8192
    )

set(DEXDUMP_INCLUDES
    ${SRC}/art/libartbase
    ${SRC}/art/libdexfile
    ${SRC}/art/libartpalette/include
    ${SRC}/tinyxml2
    ${SRC}/fmtlib/include
    ${SRC}/logging/liblog/include
    ${SRC}/libbase/include
    ${SRC}/libziparchive/include
    )

# ---------------------------------------------------------------- 生成的 operator<<
#
# 跟 aidl 的 flex/bison 同类：**Soong 会自己生成，CMake 不会。**
# libdexfile/Android.bp:156 和 libartbase/Android.bp:189 各有一个 gensrcs，
# 拿 art/tools/generate_operator_out.py 从若干头文件里的 enum 生成
# `std::ostream& operator<<(std::ostream&, 某个枚举)`。
#
# 不生成的话编译全过、**链接才炸**，而且信息很误导：
#     ld.lld: error: undefined symbol:
#       art::operator<<(std::ostream&, art::EncodedArrayValueIterator::ValueType)
# 在源码里 grep 这个函数体是找不到的 —— 它本来就不存在，是生成的。
#
# 脚本的用法是 `generate_operator_out.py <local_path> <头文件...>`，打到 stdout；
# 它会把头文件路径里的 local_path 前缀去掉再 #include，所以 local_path 要传模块根。
set(ART_GEN ${CMAKE_CURRENT_BINARY_DIR}/art-gen)
file(MAKE_DIRECTORY ${ART_GEN})
set(GEN_OP ${SRC}/art/tools/generate_operator_out.py)

set(DEXFILE_OP_HEADERS
    ${SRC}/art/libdexfile/dex/dex_file.h
    ${SRC}/art/libdexfile/dex/dex_file_layout.h
    ${SRC}/art/libdexfile/dex/dex_instruction.h
    ${SRC}/art/libdexfile/dex/dex_instruction_utils.h
    ${SRC}/art/libdexfile/dex/invoke_type.h
    )
string(JOIN " " DEXFILE_OP_HEADERS_STR ${DEXFILE_OP_HEADERS})
add_custom_command(
    OUTPUT ${ART_GEN}/dexfile_operator_out.cc
    COMMAND ${CMAKE_COMMAND} -E make_directory ${ART_GEN}
    # 脚本只往 stdout 打，要重定向；CMake 没有重定向语法，只能借一层 sh。
    # **VERBATIM 是必须的** —— 不加的话 CMake 会把整条命令按空格逐个转义，
    # sh 拿到的就不是一条完整命令了（实测：报 "Directory nonexistent"）。
    COMMAND sh -c "python3 ${GEN_OP} ${SRC}/art/libdexfile ${DEXFILE_OP_HEADERS_STR} > ${ART_GEN}/dexfile_operator_out.cc"
    DEPENDS ${GEN_OP} ${DEXFILE_OP_HEADERS}
    COMMENT "generate_operator_out.py -> dexfile_operator_out.cc"
    VERBATIM)

set(ARTBASE_OP_HEADERS
    ${SRC}/art/libartbase/arch/instruction_set.h
    ${SRC}/art/libartbase/base/allocator.h
    ${SRC}/art/libartbase/base/unix_file/fd_file.h
    )
string(JOIN " " ARTBASE_OP_HEADERS_STR ${ARTBASE_OP_HEADERS})
add_custom_command(
    OUTPUT ${ART_GEN}/artbase_operator_out.cc
    COMMAND ${CMAKE_COMMAND} -E make_directory ${ART_GEN}
    # 脚本只往 stdout 打，要重定向；CMake 没有重定向语法，只能借一层 sh。
    # **VERBATIM 是必须的** —— 不加的话 CMake 会把整条命令按空格逐个转义，
    # sh 拿到的就不是一条完整命令了（实测：报 "Directory nonexistent"）。
    COMMAND sh -c "python3 ${GEN_OP} ${SRC}/art/libartbase ${ARTBASE_OP_HEADERS_STR} > ${ART_GEN}/artbase_operator_out.cc"
    DEPENDS ${GEN_OP} ${ARTBASE_OP_HEADERS}
    COMMENT "generate_operator_out.py -> artbase_operator_out.cc"
    VERBATIM)

# ---------------------------------------------------------------- libtinyxml2
# external/tinyxml2/Android.bp 的 cc_library libtinyxml2 就一个源文件。
add_library(libtinyxml2 STATIC ${SRC}/tinyxml2/tinyxml2.cpp)
target_include_directories(libtinyxml2 PUBLIC ${SRC}/tinyxml2)

# ---------------------------------------------------------------- libartpalette
# **只要 system/palette_fake.cc。** libartpalette/Android.bp 里 apex/palette.cc 是
# android 变体（它 dlopen libartpalette-system.so），host / linux 变体用的是
# palette_fake.cc。我们编出来的是静态二进制、跑在 ARM64 Linux 上当 host 工具用，
# dlopen 那条路根本走不通。
#
# lzhiyong 那份两个都编了 —— 两个文件定义同一批 PaletteXxx 符号，靠归档顺序
# 决定链进哪个。**照 Android.bp 走，别照抄。**
add_library(libartpalette STATIC ${SRC}/art/libartpalette/system/palette_fake.cc)
target_include_directories(libartpalette PRIVATE ${DEXDUMP_INCLUDES})
target_compile_definitions(libartpalette PRIVATE ${ART_CFLAGS})

# ---------------------------------------------------------------- libartbase
# libartbase/Android.bp 的 libartbase_defaults 有 28 个，
# 另外 linux/host 变体再加 globals_unix.cc 和 mem_map_unix.cc 两个（Android.bp:65）。
add_library(libartbase STATIC
    ${SRC}/art/libartbase/arch/instruction_set.cc
    ${SRC}/art/libartbase/base/allocator.cc
    ${SRC}/art/libartbase/base/arena_allocator.cc
    ${SRC}/art/libartbase/base/arena_bit_vector.cc
    ${SRC}/art/libartbase/base/bit_vector.cc
    ${SRC}/art/libartbase/base/compiler_filter.cc
    ${SRC}/art/libartbase/base/file_magic.cc
    ${SRC}/art/libartbase/base/file_utils.cc
    ${SRC}/art/libartbase/base/flags.cc
    ${SRC}/art/libartbase/base/globals_unix.cc
    ${SRC}/art/libartbase/base/hex_dump.cc
    ${SRC}/art/libartbase/base/logging.cc
    ${SRC}/art/libartbase/base/malloc_arena_pool.cc
    ${SRC}/art/libartbase/base/mem_map.cc
    ${SRC}/art/libartbase/base/mem_map_unix.cc
    ${SRC}/art/libartbase/base/membarrier.cc
    ${SRC}/art/libartbase/base/memfd.cc
    ${SRC}/art/libartbase/base/memory_region.cc
    ${SRC}/art/libartbase/base/metrics/metrics_common.cc
    ${SRC}/art/libartbase/base/os_linux.cc
    ${SRC}/art/libartbase/base/pointer_size.cc
    ${SRC}/art/libartbase/base/runtime_debug.cc
    ${SRC}/art/libartbase/base/scoped_arena_allocator.cc
    ${SRC}/art/libartbase/base/scoped_flock.cc
    ${SRC}/art/libartbase/base/socket_peer_is_trusted.cc
    ${SRC}/art/libartbase/base/time_utils.cc
    ${SRC}/art/libartbase/base/unix_file/fd_file.cc
    ${SRC}/art/libartbase/base/unix_file/random_access_file_utils.cc
    ${SRC}/art/libartbase/base/utils.cc
    ${SRC}/art/libartbase/base/zip_archive.cc
    ${ART_GEN}/artbase_operator_out.cc
    )
target_include_directories(libartbase PRIVATE ${DEXDUMP_INCLUDES})
target_compile_definitions(libartbase PRIVATE ${ART_CFLAGS})
target_link_libraries(libartbase PUBLIC libtinyxml2)

# ---------------------------------------------------------------- libdexfile
# libdexfile/Android.bp 的 libdexfile_defaults，17 个，一个不多一个不少。
add_library(libdexfile STATIC
    ${SRC}/art/libdexfile/dex/art_dex_file_loader.cc
    ${SRC}/art/libdexfile/dex/compact_dex_file.cc
    ${SRC}/art/libdexfile/dex/compact_offset_table.cc
    ${SRC}/art/libdexfile/dex/descriptors_names.cc
    ${SRC}/art/libdexfile/dex/dex_file.cc
    ${SRC}/art/libdexfile/dex/dex_file_exception_helpers.cc
    ${SRC}/art/libdexfile/dex/dex_file_layout.cc
    ${SRC}/art/libdexfile/dex/dex_file_loader.cc
    ${SRC}/art/libdexfile/dex/dex_file_tracking_registrar.cc
    ${SRC}/art/libdexfile/dex/dex_file_verifier.cc
    ${SRC}/art/libdexfile/dex/dex_instruction.cc
    ${SRC}/art/libdexfile/dex/modifiers.cc
    ${SRC}/art/libdexfile/dex/primitive.cc
    ${SRC}/art/libdexfile/dex/signature.cc
    ${SRC}/art/libdexfile/dex/standard_dex_file.cc
    ${SRC}/art/libdexfile/dex/type_lookup_table.cc
    ${SRC}/art/libdexfile/dex/utf.cc
    ${ART_GEN}/dexfile_operator_out.cc
    )
target_include_directories(libdexfile PRIVATE ${DEXDUMP_INCLUDES})
target_compile_definitions(libdexfile PRIVATE ${ART_CFLAGS})

# ---------------------------------------------------------------- dexdump
add_executable(dexdump
    ${SRC}/art/dexdump/dexdump.cc
    ${SRC}/art/dexdump/dexdump_cfg.cc
    ${SRC}/art/dexdump/dexdump_main.cc
    )
target_include_directories(dexdump PRIVATE ${DEXDUMP_INCLUDES})
target_compile_definitions(dexdump PRIVATE ${ART_CFLAGS})
target_compile_options(dexdump PRIVATE -Wall)   # -Werror 不带，理由见 cmake/zipalign.cmake

# Android.bp 里 host 变体的 static_libs：libdexfile libartbase libbase
# libartpalette liblog libz libziparchive。libtinyxml2 是 libartbase 拖进来的。
target_link_libraries(dexdump
    libdexfile
    libartbase
    libartpalette
    libtinyxml2
    libbase
    libziparchive
    liblog
    c++_static
    dl
    z
    )

target_link_options(dexdump PRIVATE "-Wl,-z,max-page-size=16384")
