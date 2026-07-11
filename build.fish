#!/usr/bin/env fish

# fish has no `set -eu`: there is no global errexit. The compile/link commands
# below use `or exit $status` so a failed build still aborts the script.
cd (status dirname); or exit 1

# --- Unpack arguments -------------------------------------------------------
# Each bare arg becomes a flag set to 1, e.g. `./build.fish raddbg clang release`
# sets $raddbg $clang $release. `set $arg 1` works because fish expands $arg to
# the variable name first -- the same trick as bash's `declare $arg=1`.
for arg in $argv
    set $arg 1
end
test (count $argv) -eq 0; and set raddbg 1

# --- asan -------------------------------------------------------------------
# Flags are kept as *lists*, never space-joined strings: fish does not word-split
# a variable on spaces, so a list is how you pass multiple args to a command. An
# empty list ($cc_sanitize when asan is off) simply contributes nothing.
set cc_sanitize
if test "$asan" = 1
    echo "[asan enabled]"
    set cc_sanitize -fsanitize=address
end

# --- Current git commit id --------------------------------------------------
set git_hash (git describe --always --dirty)
set git_hash_full (git rev-parse HEAD)

# --- Compile/link flag definitions ------------------------------------------
set cc_cflags_gcc
set cc_cflags_clang $cc_sanitize -fdiagnostics-absolute-paths \
    -Wno-for-loop-analysis -Wno-incompatible-pointer-types-discards-qualifiers \
    -Wno-initializer-overrides -Wno-compare-distinct-pointer-types \
    -Wno-single-bit-bitfield-constant-conversion -Wno-deprecated-declarations \
    -Wno-writable-strings -Wno-unknown-warning-option -Wno-deprecated-register \
    -Wno-unused-local-typedef -msse2

# `\"` embeds a literal quote so the hash reaches the compiler as a C string
# literal: -DBUILD_GIT_HASH="abc123". (Assumes the hash contains no spaces.)
set cc_common -std=c23 -mcx16 -I../src/ -I../local/ -D_GNU_SOURCE -g \
    -DBUILD_GIT_HASH=\"$git_hash\" -DBUILD_GIT_HASH_FULL=\"$git_hash_full\" \
    -Wall -Wno-missing-braces -Wno-unused-function -Wno-unused-variable \
    -Wno-unused-but-set-variable -Wno-unused-value -D_USE_MATH_DEFINES \
    -Dstrdup=_strdup -Dgnu_printf=printf
set cc_debug -g -O0 -DBUILD_DEBUG=1 $cc_common
set cc_release -g -O2 -DBUILD_DEBUG=0 $cc_common
set cc_link -lpthread -lm -lrt -ldl

# --- Per-build settings -----------------------------------------------------
set cc_link_dll -fPIC

# --- External libraries -----------------------------------------------------
# Fedora: sudo dnf install pkgconf-pkg-config freetype-devel libX11-devel \
#         libXext-devel mesa-libGL-devel mesa-libEGL-devel
# pkg-config prints space-separated flags on a single line; `string split` turns
# that one line into a proper list of args (fish would otherwise keep it as one).
if command -q pkg-config
    set cc_font_provider (pkg-config --cflags --libs freetype2 | string split -n ' ')
    set cc_os_gfx (pkg-config --cflags --libs x11 xext | string split -n ' ')
    set cc_render (pkg-config --cflags --libs gl egl | string split -n ' ')
else
    set cc_font_provider -I/usr/include/freetype2 -lfreetype
    set cc_os_gfx -lX11 -lXext
    set cc_render -lGL -lEGL
end

# --- Choose compiler and flags ----------------------------------------------
# clang is the default; pass `gcc` to switch. $CC (if exported) overrides the
# binary name and is assumed to be a single command word.
if test "$gcc" = 1
    echo "[gcc compile]"
    set -q CC; or set -l CC gcc
    set compiler $CC $cc_cflags_gcc
else
    echo "[clang compile]"
    set -q CC; or set -l CC clang
    set compiler $CC $cc_cflags_clang
end

# debug is the default; pass `release` to switch.
if test "$release" = 1
    echo "[release mode]"
    set compile $compiler $cc_release
else
    echo "[debug mode]"
    set compile $compiler $cc_debug
end

# --- Prep directories -------------------------------------------------------
mkdir -p build local

# --- Build & run metaprogram ------------------------------------------------
# Metagen is always built debug, regardless of the release/debug choice above.
if test "$no_meta" != 1
    echo "[building metagen]"
    cd build
    $compiler $cc_debug ../src/metagen/metagen_main.c $cc_link -o metagen
    or exit $status
    ./metagen
    or exit $status
    cd ..
end

# --- Build everything (@build_targets) --------------------------------------
cd build
if test "$raddbg" = 1
    set didbuild 1
    $compile ../src/raddbg/raddbg_main.c $cc_link $cc_os_gfx $cc_render $cc_font_provider -o raddbg
    or exit $status
end
if test "$raddbg_non_graphical" = 1
    set didbuild 1
    $compile ../src/raddbg/raddbg_main.c -DWM_STUB=1 -DR_BACKEND=R_BACKEND_STUB $cc_link $cc_os_gfx $cc_render $cc_font_provider -o raddbg_non_graphical
    or exit $status
end
if test "$radbin" = 1
    set didbuild 1
    $compile ../src/radbin/radbin_main.c $cc_link -o radbin
    or exit $status
end
if test "$radlink" = 1
    set didbuild 1
    $compile ../src/linker/lnk.c $cc_link -o radlink
    or exit $status
end
if test "$torture" = 1
    set didbuild 1
    $compile ../src/torture/torture_main.c $cc_link $cc_os_gfx $cc_render $cc_font_provider -o torture
    or exit $status
end
cd ..

# --- Warn on no builds ------------------------------------------------------
if test "$didbuild" != 1
    echo '[WARNING] no valid build target specified; must use build target names as arguments to this script, like `./build.fish raddbg` or `./build.fish radlink`.'
    exit 1
end
