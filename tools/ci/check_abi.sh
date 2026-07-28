#!/usr/bin/env bash
#
# Checks the C ABI on a POSIX host: that include/phaser.h is a valid standalone
# header under independent compilers, that a C client links and runs against
# both linkage modes, and that the shared library exports exactly the documented
# public symbol set.
#
# "Independent" is the point of the compiler loop. Zig's bundled clang can
# compile this header, but a header malformed in a way Zig's own front end
# tolerates would compile in both places, which is the failure the check exists
# to catch. See docs/decisions/0014-public-header-and-toolchain-baseline.md.
#
# Usage: tools/ci/check_abi.sh INSTALL_PREFIX
#
# INSTALL_PREFIX is a `zig build --prefix` output containing include/ and lib/.

set -euo pipefail

if (($# != 1)); then
  printf 'usage: %s INSTALL_PREFIX\n' "$0" >&2
  exit 2
fi

readonly prefix=$1
readonly include_directory=$prefix/include
readonly library_directory=$prefix/lib
readonly header=$include_directory/phaser.h
readonly allow_list=tools/ci/abi_public_symbols.txt
readonly client=examples/c/abi_client.c

for required in "$header" "$allow_list" "$client"; do
  if [[ ! -f "$required" ]]; then
    printf 'missing required file: %s\n' "$required" >&2
    exit 1
  fi
done

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

readonly host=$(uname -s)
case "$host" in
  Linux) readonly shared_library=$library_directory/libphaser.so ;;
  Darwin) readonly shared_library=$library_directory/libphaser.dylib ;;
  *)
    printf 'unsupported host for this checker: %s\n' "$host" >&2
    exit 1
    ;;
esac
readonly static_library=$library_directory/libphaser.a

failures=0

note() { printf '\n== %s\n' "$1"; }
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# ---------------------------------------------------------------------------
# 1. The header compiles standalone, as C and as C++, under every independent
#    compiler this host provides.
# ---------------------------------------------------------------------------

printf '#include "phaser.h"\nint main(void) { return (int)phaser_abi_version(); }\n' \
  >"$work/probe.c"
printf '#include "phaser.h"\nint main() { return (int)phaser_abi_version(); }\n' \
  >"$work/probe.cpp"

readonly warnings=(-Wall -Wextra -Werror -pedantic)

c_compilers=()
cxx_compilers=()
for candidate in gcc clang cc; do
  if command -v "$candidate" >/dev/null 2>&1; then c_compilers+=("$candidate"); fi
done
for candidate in g++ clang++ c++; do
  if command -v "$candidate" >/dev/null 2>&1; then cxx_compilers+=("$candidate"); fi
done

if ((${#c_compilers[@]} == 0)); then
  printf 'no independent C compiler found\n' >&2
  exit 1
fi
if ((${#cxx_compilers[@]} == 0)); then
  printf 'no independent C++ compiler found\n' >&2
  exit 1
fi

note 'Header compiles as C11'
for compiler in "${c_compilers[@]}"; do
  printf -- '-- %s: %s\n' "$compiler" "$("$compiler" --version | head -1)"
  if ! "$compiler" -std=c11 "${warnings[@]}" -I"$include_directory" \
    -c "$work/probe.c" -o "$work/probe.$compiler.o"; then
    fail "$compiler could not compile phaser.h as C11"
  fi
done

note 'Header compiles as C++17'
for compiler in "${cxx_compilers[@]}"; do
  printf -- '-- %s: %s\n' "$compiler" "$("$compiler" --version | head -1)"
  if ! "$compiler" -std=c++17 "${warnings[@]}" -I"$include_directory" \
    -c "$work/probe.cpp" -o "$work/probe.$compiler.opp"; then
    fail "$compiler could not compile phaser.h as C++17"
  fi
done

# ---------------------------------------------------------------------------
# 2. The C client builds and runs against both linkage modes.
#
#    An untested linkage mode is an unsupported one, and the two differ in more
#    than a flag: static linkage resolves at build time, shared linkage exercises
#    the export macro and the dynamic loader.
# ---------------------------------------------------------------------------

note 'C client links and runs against the static library'
if "${c_compilers[0]}" -std=c11 "${warnings[@]}" -I"$include_directory" \
  "$client" "$static_library" -o "$work/client_static"; then
  if ! "$work/client_static"; then
    fail 'C client failed against the static library'
  fi
else
  fail 'C client did not build against the static library'
fi

note 'C client links and runs against the shared library'
shared_flags=(-L"$library_directory" -lphaser)
case "$host" in
  Linux) shared_flags+=(-Wl,-rpath,"$library_directory") ;;
  Darwin) shared_flags+=(-Wl,-rpath,"$library_directory") ;;
esac
if "${c_compilers[0]}" -std=c11 "${warnings[@]}" -DPHASER_SHARED \
  -I"$include_directory" "$client" "${shared_flags[@]}" \
  -o "$work/client_shared"; then
  if ! "$work/client_shared"; then
    fail 'C client failed against the shared library'
  fi
else
  fail 'C client did not build against the shared library'
fi

# ---------------------------------------------------------------------------
# 3. The shared library exports exactly the documented public symbol set.
# ---------------------------------------------------------------------------

note 'Exported symbols match the allow-list'

case "$host" in
  Linux)
    # POSIX format keeps this parseable: "name type value size".
    nm --dynamic --defined-only --format=posix "$shared_library" |
      awk '$2 ~ /^[TDBRWi]$/ { print $1 }' >"$work/exported.raw"
    ;;
  Darwin)
    # -g external only, -U defined only. Mach-O prefixes every C symbol with an
    # underscore, which is decoration rather than part of the name.
    nm -gU "$shared_library" | awk '$2 ~ /^[TDBS]$/ { print $3 }' |
      sed 's/^_//' >"$work/exported.raw"
    ;;
esac

# Symbols the platform linker contributes to every shared object, which are not
# part of any library's interface. The list is exact rather than a pattern: a
# wildcard here would be a place for a real Phaser symbol to hide.
#
# ELF adds none of these -- a cross-compiled Linux build of this library exports
# the documented set and nothing else. Mach-O adds two.
readonly platform_symbols=(
  __dso_handle      # C++ ABI handle, emitted into every Mach-O image
  _mh_dylib_header  # Mach-O header address, referenced by the dynamic loader
)

cp "$work/exported.raw" "$work/exported.filtered"
if [[ "$host" == Darwin ]]; then
  for symbol in "${platform_symbols[@]}"; do
    grep -v -x -F "$symbol" "$work/exported.filtered" >"$work/exported.next" || true
    mv "$work/exported.next" "$work/exported.filtered"
  done
fi

sort -u "$work/exported.filtered" >"$work/exported.txt"
grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$allow_list" |
  sed 's/[[:space:]]*$//' | sort -u >"$work/allowed.txt"

if ! diff -u "$work/allowed.txt" "$work/exported.txt" >"$work/symbols.diff"; then
  printf 'exported symbols do not match %s\n' "$allow_list" >&2
  printf '  lines starting "-" are documented but not exported\n' >&2
  printf '  lines starting "+" are exported but not documented\n' >&2
  cat "$work/symbols.diff" >&2
  fail 'symbol allow-list mismatch'
else
  printf 'exports exactly %s documented symbols\n' "$(wc -l <"$work/allowed.txt" | tr -d ' ')"
fi

if ((failures > 0)); then
  printf '\n%d ABI check(s) failed\n' "$failures" >&2
  exit 1
fi

printf '\nall ABI checks passed\n'
