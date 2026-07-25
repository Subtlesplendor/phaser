#!/usr/bin/env bash

set -euo pipefail

readonly zig_version=0.16.0

case "$(uname -s):$(uname -m)" in
  Darwin:arm64)
    archive_url=https://ziglang.org/download/0.16.0/zig-aarch64-macos-0.16.0.tar.xz
    archive_sha256=b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489
    ;;
  Linux:x86_64)
    archive_url=https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz
    archive_sha256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
    ;;
  *)
    printf 'unsupported Zig host: %s %s\n' "$(uname -s)" "$(uname -m)" >&2
    exit 1
    ;;
esac

readonly archive_url
readonly archive_sha256

if (($# != 1)); then
  printf 'usage: %s INSTALL_DIRECTORY\n' "$0" >&2
  exit 2
fi

readonly install_directory=$1
readonly archive_path=${install_directory}.tar.xz

if [[ -e "$install_directory" ]]; then
  printf 'installation directory already exists: %s\n' \
    "$install_directory" >&2
  exit 1
fi

if [[ "$(< .zigversion)" != "$zig_version" ]]; then
  printf '.zigversion does not match the pinned CI toolchain: expected %s\n' \
    "$zig_version" >&2
  exit 1
fi

mkdir -p -- "$install_directory"

curl \
  --fail \
  --location \
  --proto '=https' \
  --show-error \
  --silent \
  --tlsv1.2 \
  --output "$archive_path" \
  "$archive_url"

if command -v shasum >/dev/null 2>&1; then
  printf '%s  %s\n' "$archive_sha256" "$archive_path" |
    shasum --algorithm 256 --check
elif command -v sha256sum >/dev/null 2>&1; then
  printf '%s  %s\n' "$archive_sha256" "$archive_path" |
    sha256sum --check --strict
else
  printf 'no SHA-256 verification tool is available\n' >&2
  exit 1
fi

tar \
  --extract \
  --file "$archive_path" \
  --strip-components 1 \
  --directory "$install_directory"

readonly installed_version=$("$install_directory/zig" version)
if [[ "$installed_version" != "$zig_version" ]]; then
  printf 'installed Zig version is %s; expected %s\n' \
    "$installed_version" "$zig_version" >&2
  exit 1
fi
