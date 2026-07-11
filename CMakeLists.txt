# CMakeLists.txt — raddebugger (Linux / CLion)
# ---------------------------------------------------------------------------
# Reconstructed from build.fish + compile_commands.json.
#
# raddebugger is a UNITY build: each executable is a single umbrella .c that
# #includes the rest of its layer. Only the umbrella files are real translation
# units; every other .c is pulled in via #include and assumes prior context.
# That is WHY a per-TU indexer (clangd, CLion's compile_commands mode) shows red
# in the included files. Making the umbrella file a CMake *target* lets CLion
# walk the whole #include graph in-context, so symbols resolve project-wide.
#
# Place this at the repo root (next to src/, local/, build.fish), then in CLion:
#   File > Open  ->  select this CMakeLists.txt  ->  "Open as Project".
# ---------------------------------------------------------------------------

cmake_minimum_required(VERSION 4.2)   # 3.26+ understands CMAKE_C_STANDARD 23
project(raddebugger C)
set(CMAKE_C_STANDARD 23)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS ON)                 # -std=c23, not gnu23 (matches build.fish)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)       # regenerates a *complete* compile_commands.json

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Debug CACHE STRING "" FORCE)   # -O0 -g, like build.fish default
endif()

# ---- Git hashes (mirror: git describe --always --dirty / rev-parse HEAD) ----
find_package(Git QUIET)
set(RADDBG_GIT_HASH "0")
set(RADDBG_GIT_HASH_FULL "0")
if(Git_FOUND)
  execute_process(COMMAND ${GIT_EXECUTABLE} describe --always --dirty
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    OUTPUT_VARIABLE RADDBG_GIT_HASH OUTPUT_STRIP_TRAILING_WHITESPACE)
  execute_process(COMMAND ${GIT_EXECUTABLE} rev-parse HEAD
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    OUTPUT_VARIABLE RADDBG_GIT_HASH_FULL OUTPUT_STRIP_TRAILING_WHITESPACE)
endif()

# ---- Common flags (mirror: $cc_cflags_clang + $cc_common warnings) ----------
add_compile_options(
  -mcx16 -msse2 -fdiagnostics-absolute-paths
  -Wall -Wno-missing-braces -Wno-unused-function -Wno-unused-variable
  -Wno-unused-but-set-variable -Wno-unused-value
  -Wno-for-loop-analysis -Wno-incompatible-pointer-types-discards-qualifiers
  -Wno-initializer-overrides -Wno-compare-distinct-pointer-types
  -Wno-single-bit-bitfield-constant-conversion -Wno-deprecated-declarations
  -Wno-writable-strings -Wno-unknown-warning-option -Wno-deprecated-register
  -Wno-unused-local-typedef
)

add_compile_definitions(
        _GNU_SOURCE
  _USE_MATH_DEFINES
  BUILD_GIT_HASH=\"${RADDBG_GIT_HASH}\"
  BUILD_GIT_HASH_FULL=\"${RADDBG_GIT_HASH_FULL}\"
  BUILD_DEBUG=$<IF:$<CONFIG:Debug>,1,0>
  # MSVC-compat leftovers carried in from build.fish. On Linux you can almost
  # certainly delete both: nothing here calls _strdup, and gnu_printf only shows
  # up in format attributes. Kept so this matches your build 1:1 — and note that
  # -Dstrdup=_strdup is exactly the kind of define that can confuse an indexer,
  # so dropping it is worth a try if you still see stray red on string.h users.
  strdup=_strdup
  gnu_printf=printf
)

include_directories(${CMAKE_SOURCE_DIR}/src ${CMAKE_SOURCE_DIR}/local)

# ---- External libraries (mirror: the pkg-config calls in build.fish) --------
#   sudo dnf install pkgconf-pkg-config freetype-devel libX11-devel \
#        libXext-devel mesa-libGL-devel mesa-libEGL-devel
find_package(PkgConfig REQUIRED)
pkg_check_modules(FONT   REQUIRED IMPORTED_TARGET freetype2)   # $cc_font_provider
pkg_check_modules(OSGFX  REQUIRED IMPORTED_TARGET x11 xext)    # $cc_os_gfx
pkg_check_modules(RENDER REQUIRED IMPORTED_TARGET gl egl)      # $cc_render
find_package(Threads REQUIRED)

set(RADDBG_GFX_LIBS PkgConfig::FONT PkgConfig::OSGFX PkgConfig::RENDER)
set(RADDBG_SYS_LIBS Threads::Threads m rt dl)                  # $cc_link

# ==== metaprogram (build.fish always builds this first, always in debug) =====
add_executable(metagen src/metagen/metagen_main.c)
target_compile_options(metagen PRIVATE -O0 -g)
target_compile_definitions(metagen PRIVATE BUILD_DEBUG=1)
target_link_libraries(metagen PRIVATE ${RADDBG_SYS_LIBS})

# metagen must run to generate the *.meta.* sources that raddbg #includes.
# You already ran build.fish, so those files exist on disk and CLion will index
# fine right now with this OFF. Flip it ON if you want CMake itself to own
# codegen -- but verify the working directory: build.fish runs metagen as
# `cd build; ./metagen`, i.e. CWD is one level below the repo root. If metagen
# writes relative to CWD (not into src/), adjust WORKING_DIRECTORY accordingly.
option(RADDBG_RUN_METAGEN "Run metagen during the CMake build" OFF)
if(RADDBG_RUN_METAGEN)
  add_custom_target(raddbg_codegen ALL
    COMMAND $<TARGET_FILE:metagen>
    WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
    DEPENDS metagen
    COMMENT "Running metagen (code generation)"
    VERBATIM)
endif()

# ==== raddbg (default target from build.fish) ===============================
add_executable(raddbg src/raddbg/raddbg_main.c)
target_link_libraries(raddbg PRIVATE ${RADDBG_GFX_LIBS} ${RADDBG_SYS_LIBS})
if(RADDBG_RUN_METAGEN)
  add_dependencies(raddbg raddbg_codegen)
endif()

# ---- Show every source in CLion WITHOUT compiling it as its own TU ----------
# In a unity build the other .c/.h files are #included, not compiled separately.
# HEADER_FILE_ONLY attaches them to the target (project tree + index) while
# telling CMake NOT to build them standalone. This is the key line that gives
# you the "normal project" feel.
file(GLOB_RECURSE RADDBG_TREE CONFIGURE_DEPENDS
  ${CMAKE_SOURCE_DIR}/src/*.c ${CMAKE_SOURCE_DIR}/src/*.h)
list(REMOVE_ITEM RADDBG_TREE                       # the real TUs stay compilable
  ${CMAKE_SOURCE_DIR}/src/raddbg/raddbg_main.c
  ${CMAKE_SOURCE_DIR}/src/metagen/metagen_main.c)
set_source_files_properties(${RADDBG_TREE} PROPERTIES HEADER_FILE_ONLY ON)
target_sources(raddbg PRIVATE ${RADDBG_TREE})

# ==== Optional extra targets (uncomment as needed; straight from build.fish) =
# Note: other umbrella entry points (radbin_main.c, lnk.c, torture_main.c) are
# swept into RADDBG_TREE above as HEADER_FILE_ONLY, so they render standalone and
# will show red. To index one properly, enable it here as a real target.
#
# add_executable(raddbg_non_graphical src/raddbg/raddbg_main.c)
# target_compile_definitions(raddbg_non_graphical PRIVATE WM_STUB=1 R_BACKEND=R_BACKEND_STUB)
# target_link_libraries(raddbg_non_graphical PRIVATE ${RADDBG_GFX_LIBS} ${RADDBG_SYS_LIBS})
#
# add_executable(radbin  src/radbin/radbin_main.c)
# target_link_libraries(radbin  PRIVATE ${RADDBG_SYS_LIBS})
#
# add_executable(radlink src/linker/lnk.c)
# target_link_libraries(radlink PRIVATE ${RADDBG_SYS_LIBS})
#
# add_executable(torture src/torture/torture_main.c)
# target_link_libraries(torture PRIVATE ${RADDBG_GFX_LIBS} ${RADDBG_SYS_LIBS})
