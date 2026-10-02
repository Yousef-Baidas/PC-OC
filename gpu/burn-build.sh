#!/usr/bin/env bash
set -euo pipefail
# burn-build.sh: download the gpu_burn source pinned in gpu/burn.pin, check its sha256 and
# build it in ${XDG_CACHE_HOME:-$HOME/.cache}/pc-oc/gpu-burn/<commit>/. Run it as your own
# user, never as root. The last stdout line is the build directory; it holds gpu_burn,
# compare.fatbin and the stamp file `built` (the pin's sha256, written last). With a
# matching stamp nothing is downloaded or built. Any failure exits 1 and leaves no stamp.
# Nothing of the download is unpacked before its sha256 matches the pin.
# Makefile variables at the pinned commit (gpu-burn): CUDAPATH (default /usr or
# /usr/local/cuda, neither is where Arch puts CUDA) gives NVCC := ${CUDAPATH}/bin/nvcc, the
# include directory and the library and rpath directories; COMPUTE ?= 75 gives
# -arch=compute_75 and stays at its default; CCPATH is appended to PATH for nvcc and stays
# empty. The compare kernel is compare.fatbin (COMPARE_KERNEL, gpu_burn-drv.cpp:33), which
# gpu_burn opens relative to its working directory.
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

here="$(dirname "${BASH_SOURCE[0]}")"
URL_BASE=https://github.com/wilicc/gpu-burn/archive/
CUDA_ROOT=/opt/cuda

# fail <msg>: die in the name of this script
fail() {
  die gpu "burn-build: $1"
}

is_root && fail "run it as your own user, not root"
(($# == 0)) || {
  echo "pc-oc: gpu: burn-build: usage: burn-build.sh" >&2
  exit 2
}

mapfile -t pin <"$here/burn.pin" || fail "burn.pin: unreadable"
# four lines: version, url, sha256, source
[[ -v pin[3] && ! -v pin[4] && "${pin[0]}" =~ ^version=[0-9a-f]{40}$ &&
  "${pin[2]}" =~ ^sha256=[0-9a-f]{64}$ && "${pin[3]}" == source=gpu-burn ]] ||
  fail "burn.pin: want version=<40 hex>, url=, sha256=<64 hex>, source=gpu-burn"
version="${pin[0]#version=}"
url="${pin[1]#url=}"
sha256="${pin[2]#sha256=}"
[[ "${pin[1]}" == "url=$URL_BASE$version.tar.gz" ]] ||
  fail "burn.pin: url is not $URL_BASE$version.tar.gz"

cache="${XDG_CACHE_HOME:-${HOME:+$HOME/.cache}}"
[[ "$cache" == /* ]] || fail "no cache directory: set HOME"
build_dir="$cache/pc-oc/gpu-burn/$version"

if [[ -f "$build_dir/built" && -x "$build_dir/gpu_burn" && -f "$build_dir/compare.fatbin" ]] &&
  [[ "$(<"$build_dir/built")" == "$sha256" ]]; then
  printf '%s\n' "$build_dir"
  exit 0
fi

# a build that is not the pin's is not kept: the stamp goes first, so a failure below
# leaves none
rm -rf "$build_dir" || fail "cannot remove $build_dir"
mkdir -p "$build_dir" || fail "cannot create $build_dir"
tarball="$build_dir/download.$$.tar.gz"
trap 'rm -f "$tarball"' EXIT

# GitHub answers the archive url with a redirect to codeload.github.com; both hops https
curl --proto '=https' --proto-redir '=https' --fail --location --silent --show-error \
  --connect-timeout 30 --max-time 300 --output "$tarball" "$url" ||
  fail "download failed: $url"
got="$(sha256sum <"$tarball" | cut -d' ' -f1)" || fail "sha256sum failed: $tarball"
if [[ "$got" != "$sha256" ]]; then
  rm -f "$tarball" || :
  fail "sha256 mismatch: want $sha256 got $got"
fi

# the archive has one top directory, gpu-burn-<commit>
tar -xzf "$tarball" -C "$build_dir" --strip-components=1 "gpu-burn-$version" ||
  fail "cannot extract $tarball"
rm -f "$tarball" || :

# build output goes to stderr: stdout carries the directory only
make -C "$build_dir" "CUDAPATH=$CUDA_ROOT" >&2 || fail "make failed in $build_dir"
[[ -x "$build_dir/gpu_burn" ]] || fail "make left no gpu_burn in $build_dir"
[[ -f "$build_dir/compare.fatbin" ]] || fail "make left no compare.fatbin in $build_dir"

printf '%s\n' "$sha256" >"$build_dir/built" || fail "cannot write $build_dir/built"
printf '%s\n' "$build_dir"
