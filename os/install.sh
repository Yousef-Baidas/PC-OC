#!/usr/bin/bash
set -euo pipefail
# sudo os/install.sh: copy the reviewed root scripts to ${DESTDIR:-}/usr/local/lib/pc-oc/
# and install etc/sudoers.d/pc-oc (docs/adr/0001). Everything is copied to a root-owned
# staging dir first; the checks and the install read only that copy, never the repo.

# same reason as pc-oc: under sudo, look commands up only in root-owned /usr/bin
export PATH=/usr/bin
umask 022
# a git hook exports GIT_DIR and friends; left set, git below would read another repo
unset "${!GIT_@}"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$here/lib/common.sh"
# same list as pc-oc
components=(cpu ram gpu os toolchain)
dest="${DESTDIR:-}"

is_root || [[ -n "$dest" ]] || die os "must run as root: sudo os/install.sh (tests set DESTDIR)"

# git runs as the calling user: a repo config can name commands (core.fsmonitor, filters)
# that must never run as root
as_user=()
if is_root; then
  [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]] || die os "run through sudo from your user, so git does not run as root"
  as_user=(setpriv --reuid="$SUDO_UID" --regid="$SUDO_GID" --clear-groups)
fi
git_user() {
  "${as_user[@]}" env GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C "$here" "$@"
}
head="$(git_user rev-parse HEAD)" || die os "git rev-parse HEAD failed in $here"
changes="$(git_user status --porcelain)" || die os "git status failed in $here"

stage="$(mktemp -d /tmp/pc-oc-install.XXXXXX)" || die os "mktemp failed"
trap 'rm -rf "$stage" || true' EXIT
tree="$stage/pc-oc"
mkdir "$tree" || die os "mkdir $tree failed"

# every regular file directly under a component dir is copied: verb scripts run, the rest
# (scx_loader.toml, gpu/values) is data they read. -RP copies a symlink as a symlink, so
# the check below sees it instead of its target
scripts=(pc-oc)
files=(pc-oc)
for c in "${components[@]}"; do
  [[ -d "$here/$c" ]] || continue
  while IFS= read -r -d '' name; do
    if [[ -d "$here/$c/$name" && ! -L "$here/$c/$name" ]]; then
      die os "subdirectory in component dir: $c/$name"
    fi
    files+=("$c/$name")
    case "$name" in
      apply.sh | revert.sh | probe.sh) scripts+=("$c/$name") ;;
    esac
  done < <(find "$here/$c" -mindepth 1 -maxdepth 1 -printf '%f\0' | LC_ALL=C sort -z)
done
for f in "${files[@]}"; do
  mkdir -p "$tree/$(dirname "$f")" || die os "mkdir for $f failed"
  cp -RP "$here/$f" "$tree/$f" || die os "copy $f failed"
done
cp -RP "$here/lib" "$tree/lib" || die os "copy lib failed"
cp -RP "$here/etc/sudoers.d/pc-oc" "$stage/sudoers" || die os "copy etc/sudoers.d/pc-oc failed"

# from here on only the staged copy is read
odd="$(find "$stage" ! -type f ! -type d)" || die os "find $stage failed"
[[ -z "$odd" ]] || die os "not a regular file: ${odd//$'\n'/ }"
chmod 0440 "$stage/sudoers" || die os "chmod sudoers failed"
visudo -cf "$stage/sudoers" >/dev/null || die os "etc/sudoers.d/pc-oc fails visudo -cf; nothing installed"

printf '%s%s\n' "$head" "${changes:+-dirty}" >"$tree/VERSION" || die os "write VERSION failed"
find "$tree" -type d -exec chmod 0755 {} + || die os "chmod dirs failed"
find "$tree" -type f -exec chmod 0644 {} + || die os "chmod files failed"
(cd "$tree" && chmod 0755 "${scripts[@]}") || die os "chmod scripts failed"

mkdir -p "$dest/usr/local/lib" "$dest/etc/sudoers.d" || die os "mkdir under ${dest:-/} failed"
rm -rf "$dest/usr/local/lib/pc-oc" || die os "remove old $dest/usr/local/lib/pc-oc failed"
mv "$tree" "$dest/usr/local/lib/pc-oc" || die os "move to $dest/usr/local/lib/pc-oc failed"
# sudoers.d skips dotted names, so the half-written temp is never read; mv swaps it in whole
cp "$stage/sudoers" "$dest/etc/sudoers.d/.pc-oc.new" || die os "copy sudoers to $dest/etc/sudoers.d failed"
mv -f "$dest/etc/sudoers.d/.pc-oc.new" "$dest/etc/sudoers.d/pc-oc" || die os "install sudoers failed"
echo "pc-oc: os: installed $head${changes:+-dirty} to ${dest:-}/usr/local/lib/pc-oc"
