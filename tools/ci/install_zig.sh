#!/usr/bin/env bash

set -euo pipefail

readonly zig_version=0.16.0

archive_format=tar.xz
executable_name=zig

case "$(uname -s):$(uname -m)" in
  Darwin:arm64)
    archive_url=https://ziglang.org/download/0.16.0/zig-aarch64-macos-0.16.0.tar.xz
    archive_sha256=b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489
    ;;
  Linux:x86_64)
    archive_url=https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz
    archive_sha256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
    ;;
  # Windows runners run this through Git Bash, whose `uname -s` reports the
  # MSYS/MinGW environment rather than "Windows". Zig ships a zip there, not a
  # tarball, so the extraction path differs too.
  MINGW*:x86_64 | MSYS*:x86_64 | CYGWIN*:x86_64)
    archive_url=https://ziglang.org/download/0.16.0/zig-x86_64-windows-0.16.0.zip
    archive_sha256=68659eb5f1e4eb1437a722f1dd889c5a322c9954607f5edcf337bc3684a75a7e
    archive_format=zip
    executable_name=zig.exe
    ;;
  *)
    printf 'unsupported Zig host: %s %s\n' "$(uname -s)" "$(uname -m)" >&2
    exit 1
    ;;
esac

readonly archive_url
readonly archive_sha256
readonly archive_format
readonly executable_name

if (($# != 1)); then
  printf 'usage: %s INSTALL_DIRECTORY\n' "$0" >&2
  exit 2
fi

readonly install_directory=$1
readonly archive_path=${install_directory}.${archive_format}

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

case "$archive_format" in
  tar.xz)
    tar \
      --extract \
      --file "$archive_path" \
      --strip-components 1 \
      --directory "$install_directory"
    ;;
  zip)
    # unzip has no --strip-components, so extract and lift the single top-level
    # directory the archive contains.
    unzip -q "$archive_path" -d "$install_directory.staging"
    extracted=$(find "$install_directory.staging" -mindepth 1 -maxdepth 1 -type d)
    if [[ ! -d "$extracted" ]]; then
      printf 'unexpected archive layout in %s\n' "$archive_path" >&2
      exit 1
    fi
    mv "$extracted"/* "$install_directory/"
    rm -rf -- "$install_directory.staging"
    ;;
  *)
    printf 'unsupported archive format: %s\n' "$archive_format" >&2
    exit 1
    ;;
esac

readonly zig_executable=$install_directory/$executable_name
readonly installed_version=$("$zig_executable" version)
if [[ "$installed_version" != "$zig_version" ]]; then
  printf 'installed Zig version is %s; expected %s\n' \
    "$installed_version" "$zig_version" >&2
  exit 1
fi
