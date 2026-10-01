#!/usr/bin/env bash
set -euo pipefail
# One marked block in a user file. Source after lib/common.sh; do not execute it.
# Stock is "no block": there is no state directory, and every byte outside the block survives
# block_apply and block_remove, except the one newline block_apply may add before BEGIN.
# A marker line is a line that equals the marker after trailing whitespace is dropped.
# Bytes are moved with head, tail and cat, never through a shell variable, so NUL bytes survive.
# Contract #116.

BLOCK_BEGIN='# >>> pc-oc wiring >>>'
BLOCK_END='# <<< pc-oc wiring <<<'

# _block_scan <file>: set _BLOCK_STATE to absent | present | malformed and, when present,
# _BLOCK_B and _BLOCK_E to the line numbers of BEGIN and END. A missing file is absent.
# Returns 1 when <file> exists and is not a readable regular file.
_block_scan() {
  local out
  _BLOCK_STATE=absent _BLOCK_B=0 _BLOCK_E=0
  [[ -e "$1" || -L "$1" ]] || return 0
  [[ -f "$1" && -r "$1" ]] || return 1
  # <file> comes in on stdin: awk would read an operand holding = as an assignment
  out="$({ BLOCK_BEGIN="$BLOCK_BEGIN" BLOCK_END="$BLOCK_END" LC_ALL=C awk '
    {
      l = $0
      sub(/[[:space:]]+$/, "", l)
      if (l == ENVIRON["BLOCK_BEGIN"]) { nb++; lb = NR }
      if (l == ENVIRON["BLOCK_END"]) { ne++; le = NR }
    }
    END {
      if (nb + ne == 0) print "absent 0 0"
      else if (nb == 1 && ne == 1 && lb < le) print "present", lb, le
      else print "malformed 0 0"
    }' <"$1"; } 2>/dev/null)" || return 1
  read -r _BLOCK_STATE _BLOCK_B _BLOCK_E <<<"$out" || return 1
}

# _block_unterminated <file>: return 0 when <file> is not empty and its last byte is not a newline.
_block_unterminated() {
  [[ -s "$1" && "$(tail -c 1 -- "$1" 2>/dev/null | od -An -tx1)" != *0a* ]]
}

# _block_fail <tmp> <what>: remove <tmp>, then die.
_block_fail() {
  rm -f -- "$1" || :
  die block "$2"
}

# block_state <file>: print absent | present | malformed and return 0.
# absent: no file, or no marker line. present: exactly one BEGIN line followed later by exactly one END line.
# malformed: anything else (BEGIN without END, END first, two pairs, nested).
# Dies when <file> exists and cannot be read as a regular file.
block_state() {
  [[ $# -eq 1 ]] || die block "usage: block_state <file>"
  _block_scan "$1" || die block "cannot read $1"
  printf '%s\n' "$_BLOCK_STATE"
}

# block_matches <file> <src>: return 0 when <file> is present and the lines between the markers are
# byte-equal to <src>; else 1. Silent.
block_matches() {
  [[ $# -eq 2 ]] || die block "usage: block_matches <file> <src>"
  _block_scan "$1" || return 1
  [[ "$_BLOCK_STATE" == present && -f "$2" && -r "$2" ]] || return 1
  # head first: it stops at END by itself, so no reader closes a pipe on a writer under pipefail
  head -n "$((_BLOCK_E - 1))" -- "$1" 2>/dev/null | tail -n "+$((_BLOCK_B + 1))" 2>/dev/null |
    cmp -s -- - "$2" 2>/dev/null || return 1
}

# block_apply <file> <src>: put <src> between the markers in <file>.
#   no file: create parent dirs and the file (mode 0644) holding BEGIN, <src>, END.
#   absent: append BEGIN, <src>, END; if the file does not end in a newline, add one first.
#   present: replace the lines between the markers; nothing is written when they already equal <src>.
# Dies with `pc-oc: block: <what>` and leaves <file> untouched when: <file> is malformed, is a symlink,
# or exists and is not a regular file; <src> is unreadable, contains a marker line, or is not empty
# and does not end in a newline (END would not start a line).
# Writes a temp file in the same directory, checks it, then mv; an existing file keeps its mode.
# Reads back with block_matches before returning 0.
block_apply() {
  [[ $# -eq 2 ]] || die block "usage: block_apply <file> <src>"
  local file="$1" src="$2" state b e tmp
  [[ ! -L "$file" ]] || die block "$file is a symlink"
  [[ ! -e "$file" || -f "$file" ]] || die block "$file is not a regular file"
  [[ -f "$src" && -r "$src" ]] || die block "cannot read $src"
  _block_scan "$src" || die block "cannot read $src"
  [[ "$_BLOCK_STATE" == absent ]] || die block "$src contains a marker line"
  ! _block_unterminated "$src" || die block "$src does not end in a newline"
  _block_scan "$file" || die block "cannot read $file"
  [[ "$_BLOCK_STATE" != malformed ]] || die block "malformed block in $file"
  state="$_BLOCK_STATE" b="$_BLOCK_B" e="$_BLOCK_E"
  if [[ ! -e "$file" ]]; then
    state=new
    mkdir -p -- "$(dirname -- "$file")" 2>/dev/null || die block "cannot create the directory of $file"
  elif block_matches "$file" "$src"; then
    return 0
  fi
  tmp="$(mktemp -- "$file.XXXXXX" 2>/dev/null)" || die block "cannot write $file"
  {
    case "$state" in
      present) head -n "$b" -- "$file" && cat -- "$src" && tail -n "+$e" -- "$file" ;;
      absent)
        cat -- "$file" && { ! _block_unterminated "$file" || printf '\n'; } &&
          printf '%s\n' "$BLOCK_BEGIN" && cat -- "$src" && printf '%s\n' "$BLOCK_END"
        ;;
      new) printf '%s\n' "$BLOCK_BEGIN" && cat -- "$src" && printf '%s\n' "$BLOCK_END" ;;
    esac
  } >"$tmp" 2>/dev/null || _block_fail "$tmp" "cannot write $file"
  if [[ "$state" == new ]]; then
    chmod 0644 -- "$tmp" 2>/dev/null || _block_fail "$tmp" "cannot set the mode of $file"
  else
    chmod --reference="$file" -- "$tmp" 2>/dev/null || _block_fail "$tmp" "cannot set the mode of $file"
  fi
  # checked before the mv, so a bad render never replaces <file>
  block_matches "$tmp" "$src" || _block_fail "$tmp" "cannot write $file"
  mv -f -- "$tmp" "$file" 2>/dev/null || _block_fail "$tmp" "cannot write $file"
  block_matches "$file" "$src" || die block "readback of $file failed"
}

# block_remove <file>: delete BEGIN, the body and END. If only whitespace is left, delete the file.
# Returns 0 when absent (nothing to do). Dies, file untouched, when malformed, a symlink,
# or not a regular file.
block_remove() {
  [[ $# -eq 1 ]] || die block "usage: block_remove <file>"
  local file="$1" b e tmp rc=0
  [[ ! -L "$file" ]] || die block "$file is a symlink"
  [[ -e "$file" ]] || return 0
  [[ -f "$file" ]] || die block "$file is not a regular file"
  _block_scan "$file" || die block "cannot read $file"
  [[ "$_BLOCK_STATE" != malformed ]] || die block "malformed block in $file"
  [[ "$_BLOCK_STATE" == present ]] || return 0
  b="$_BLOCK_B" e="$_BLOCK_E"
  tmp="$(mktemp -- "$file.XXXXXX" 2>/dev/null)" || die block "cannot write $file"
  { head -n "$((b - 1))" -- "$file" && tail -n "+$((e + 1))" -- "$file"; } >"$tmp" 2>/dev/null ||
    _block_fail "$tmp" "cannot write $file"
  _block_scan "$tmp" || _block_fail "$tmp" "cannot write $file"
  [[ "$_BLOCK_STATE" == absent ]] || _block_fail "$tmp" "cannot write $file"
  # grep: 0 a byte that is not whitespace is left, 1 none is; anything else is an error, never a delete
  LC_ALL=C grep -aq '[^[:space:]]' -- "$tmp" 2>/dev/null || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    chmod --reference="$file" -- "$tmp" 2>/dev/null || _block_fail "$tmp" "cannot set the mode of $file"
    mv -f -- "$tmp" "$file" 2>/dev/null || _block_fail "$tmp" "cannot write $file"
    _block_scan "$file" || die block "readback of $file failed"
    [[ "$_BLOCK_STATE" == absent ]] || die block "readback of $file failed"
  elif [[ "$rc" -eq 1 ]]; then
    rm -f -- "$tmp" || :
    rm -f -- "$file" 2>/dev/null || die block "cannot remove $file"
    [[ ! -e "$file" ]] || die block "readback of $file failed"
  else
    _block_fail "$tmp" "cannot read $file"
  fi
}
