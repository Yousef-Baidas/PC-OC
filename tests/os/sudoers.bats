#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Contract #26. The lint lives here; fixtures/sudoers/ holds one good file and one
# copy of it per forbidden property, so each red case is shown on a broken fixture.

setup_file() {
  local f="$BATS_TEST_DIRNAME/../../etc/sudoers.d/pc-oc"
  f="$(cd "$(dirname "$f")" && pwd)/pc-oc"
  printf '# opened %s sha256=%s, plus %s fixtures in tests/os/fixtures/sudoers\n' \
    "$f" "$(sha256sum <"$f" | cut -d' ' -f1)" "$(find "$BATS_TEST_DIRNAME/fixtures/sudoers" -type f | wc -l)" >&3
}

setup() {
  SUDOERS="$BATS_TEST_DIRNAME/../../etc/sudoers.d/pc-oc"
  FIX="$BATS_TEST_DIRNAME/fixtures/sudoers"
}

# sudoers_lint <file>: one "<file>:<n>: <reason>: <line>" per bad line, exit 1 if any,
# or if the file has no rule at all. Allowed: one NOPASSWD rule per line whose whole
# command is /usr/local/lib/pc-oc/pc-oc <verb> <component>.
sudoers_lint() {
  local n=0 rules=0 bad=0 line cmdline cmd why
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    if [[ "$line" =~ ^[[:space:]]*[#@]include ]]; then
      why=include
    else
      line="${line%%#*}"
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -n "$line" ]] || continue
      cmdline="${line#*NOPASSWD:}"
      cmdline="${cmdline#"${cmdline%%[![:space:]]*}"}"
      cmd="${cmdline%% *}"
      why=""
      if [[ "$line" == *SETENV* ]]; then
        why=SETENV
      elif [[ "$line" == *env_keep* ]]; then
        why=env_keep
      elif [[ "$line" == *[\*\?\[\]]* ]]; then
        why=wildcard
      elif [[ "$line" == *\\ || "$line" == *,* ]]; then
        why="more than one command"
      elif [[ "$line" != *NOPASSWD:* ]]; then
        why="not a NOPASSWD rule"
      elif [[ "$cmd" != /* ]]; then
        why="relative path"
      elif [[ "$cmd" != /usr/local/lib/pc-oc/* || "$cmd" == *..* ]]; then
        why="path outside /usr/local/lib/pc-oc/"
      elif ! [[ "$cmdline" =~ ^/usr/local/lib/pc-oc/pc-oc\ (apply|revert|probe)\ (cpu|ram|gpu|os|toolchain|all)$ ]]; then
        why="not an allowed pc-oc command"
      else
        rules=$((rules + 1))
        continue
      fi
    fi
    printf '%s:%s: %s: %s\n' "$1" "$n" "$why" "$line"
    bad=1
  done <"$1"
  if [[ "$rules" -eq 0 ]]; then
    printf '%s: no rule\n' "$1"
    bad=1
  fi
  return "$bad"
}

@test "etc/sudoers.d/pc-oc passes visudo -cf" {
  run visudo -cf "$SUDOERS"
  [ "$status" -eq 0 ]
}

@test "etc/sudoers.d/pc-oc passes the lint" {
  run sudoers_lint "$SUDOERS"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "the lint passes the good fixture" {
  run sudoers_lint "$FIX/good"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "the lint is red on a wildcard" {
  run sudoers_lint "$FIX/wildcard"
  [ "$status" -eq 1 ]
  [ "$output" = "$FIX/wildcard:2: wildcard: tuff ALL=(root) NOPASSWD: /usr/local/lib/pc-oc/pc-oc apply *" ]
}

@test "the lint is red on a relative path" {
  run sudoers_lint "$FIX/relative"
  [ "$status" -eq 1 ]
  [ "$output" = "$FIX/relative:4: relative path: tuff ALL=(root) NOPASSWD: pc-oc probe cpu" ]
}

@test "the lint is red on a path outside /usr/local/lib/pc-oc/" {
  run sudoers_lint "$FIX/outside"
  [ "$status" -eq 1 ]
  [ "$output" = "$FIX/outside:4: path outside /usr/local/lib/pc-oc/: tuff ALL=(root) NOPASSWD: /usr/local/bin/pc-oc probe cpu" ]
}

@test "the lint is red on SETENV" {
  run sudoers_lint "$FIX/setenv"
  [ "$status" -eq 1 ]
  [ "$output" = "$FIX/setenv:4: SETENV: tuff ALL=(root) NOPASSWD:SETENV: /usr/local/lib/pc-oc/pc-oc probe cpu" ]
}

@test "the lint is red on env_keep" {
  run sudoers_lint "$FIX/env-keep"
  [ "$status" -eq 1 ]
  [ "$output" = "$FIX/env-keep:2: env_keep: Defaults!/usr/local/lib/pc-oc/pc-oc env_keep += \"SYSFS_ROOT PC_OC_STATE\"" ]
}
