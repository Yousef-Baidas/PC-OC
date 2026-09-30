#!/usr/bin/env bash
set -euo pipefail
# compile.sh [runs]: time a pinned kernel defconfig build; input.* lines, then result.compile.*.
# Pin: bench/kernel.pin. Tag 6.18.54 is longterm per https://www.kernel.org/releases.json;
# its sha256 is from the kernel.org checksum file named in `source=`.
# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

here="$(dirname "${BASH_SOURCE[0]}")"
runs="${1:-3}"
if [[ ! "$runs" =~ ^[0-9]+$ ]] || [ "$runs" -lt 1 ]; then
  echo "pc-oc: bench: usage: compile.sh [runs>=1]" >&2
  exit 2
fi

# pin_get <key>: value of key= in kernel.pin
pin_get() {
  local v
  v="$(sed -n "s/^$1=//p" "$here/kernel.pin")" || die bench "kernel.pin: unreadable"
  [ -n "$v" ] || die bench "kernel.pin: missing $1"
  printf '%s\n' "$v"
}

# need <tool> <install hint>: die unless <tool> is on PATH
need() {
  command -v "$1" >/dev/null || die bench "$1 not found ($2)"
}

# the kernel build's own tools; checked before any download
need make "pacman -S make"
need gcc "pacman -S gcc"
need bc "pacman -S bc"
need flex "pacman -S flex"
need bison "pacman -S bison"
need perl "pacman -S perl"
need cpio "pacman -S cpio"
need openssl "pacman -S openssl"

version="$(pin_get version)"
url="$(pin_get url)"
sha256="$(pin_get sha256)"

cache="${XDG_CACHE_HOME:-$HOME/.cache}/pc-oc"
mkdir -p "$cache" || die bench "cannot create $cache"
tarball="$cache/${url##*/}"
[ -s "$tarball" ] || curl -fsSL -o "$tarball" "$url" || {
  rm -f "$tarball"
  die bench "download failed: $url"
}
got="$(sha256sum <"$tarball" | cut -d' ' -f1)" || die bench "sha256sum failed: $tarball"
if [ "$got" != "$sha256" ]; then
  rm -f "$tarball"
  die bench "sha256 mismatch: want $sha256 got $got"
fi

work="$(mktemp -d)" || die bench "mktemp failed"
trap 'rm -rf "$work"' EXIT
items="$(tar -tf "$tarball" | wc -l)" || die bench "tar list failed: $tarball"
bytes="$(wc -c <"$tarball")" || die bench "cannot read $tarball"
tar -xf "$tarball" -C "$work" || die bench "tar extract failed: $tarball"
srcdir="$(find "$work" -mindepth 1 -maxdepth 1 -type d | head -1)"
[ -n "$srcdir" ] || die bench "tarball has no top directory"
cd "$srcdir" || die bench "cannot enter $srcdir"

jobs="$(nproc)"
printf 'input.source=%s bytes=%s items=%s\n' "$tarball" "$bytes" "$items"
printf 'input.kernel_version=%s\n' "$version"
printf 'input.sha256=%s\n' "$sha256"
printf 'input.gcc=%s\n' "$(gcc --version | head -1)"
printf 'input.make=%s\n' "$(make --version | head -1)"
printf 'input.nproc=%s\n' "$jobs"
printf 'input.runs=%s\n' "$runs"

make defconfig >/dev/null || die bench "make defconfig failed"
times=()
for ((i = 1; i <= runs; i++)); do
  make clean >/dev/null || die bench "make clean failed"
  start="${EPOCHREALTIME/[.,]/}"
  make -j"$jobs" >/dev/null || die bench "make -j$jobs failed"
  end="${EPOCHREALTIME/[.,]/}"
  t="$(awk -v d="$((end - start))" 'BEGIN { printf "%.3f", d / 1e6 }')"
  times+=("$t")
  printf 'result.compile.run%d_s=%s\n' "$i" "$t"
done
median="$(printf '%s\n' "${times[@]}" | sort -g |
  awk '{ a[NR] = $1 } END { printf "%.3f", NR % 2 ? a[(NR + 1) / 2] : (a[NR / 2] + a[NR / 2 + 1]) / 2 }')"
printf 'result.compile.median_s=%s\n' "$median"
