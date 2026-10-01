#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Contract #124. systemd/pc-oc-gpu.service is read as text and by systemd-analyze verify; nothing
# here installs, enables or starts it. Every case first needs the file: a `no such line` check
# would pass on a missing unit.

setup_file() {
  local f
  f="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/systemd/pc-oc-gpu.service"
  if [[ -r "$f" ]]; then
    printf '# opened %s sha256=%s, 1 file, %s lines\n' "$f" "$(sha256sum <"$f" | cut -d' ' -f1)" \
      "$(wc -l <"$f")" >&3
  else
    printf '# opened %s: missing, 0 files\n' "$f" >&3
  fi
}

setup() {
  unit="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/systemd/pc-oc-gpu.service"
  # verify runs in a namespace with no network and an empty /run: the running systemd and its
  # bus are out of reach, so the result comes from files only
  cat >"$BATS_TEST_TMPDIR/guard.sh" <<'EOF'
#!/usr/bin/bash
mount -t tmpfs tmpfs /run || exit 97
[[ -z "$(ls -A /run)" ]] || exit 97
exec "$@"
EOF
}

# only <key> <line>: the unit sets <key> exactly once and that line is <line>, byte for byte
only() {
  [ -r "$unit" ]
  mapfile -t found < <(grep -E "^[[:space:]]*$1[[:space:]]*=" "$unit")
  [ "${#found[@]}" -eq 1 ] || {
    echo "want one $1= line, found ${#found[@]}: ${found[*]}" >&3
    return 1
  }
  [ "${found[0]}" = "$2" ] || {
    echo "$1 line is '${found[0]}', want '$2'" >&3
    return 1
  }
}

# none <key regex>: the unit has no line setting a key that matches
none() {
  [ -r "$unit" ]
  mapfile -t found < <(grep -E "^[[:space:]]*$1[[:space:]]*=" "$unit")
  [ "${#found[@]}" -eq 0 ] || {
    echo "unit sets ${found[*]}" >&3
    return 1
  }
}

# verify_in_fake_root <mode of the ExecStart file>: systemd-analyze verify against a root that
# holds only the unit and a file at the ExecStart path, so nothing installed on the PC is read
verify_in_fake_root() {
  [ -r "$unit" ]
  local fake="$BATS_TEST_TMPDIR/fakeroot"
  mkdir -p "$fake/etc/systemd/system" "$fake/usr/local/lib/pc-oc"
  cp "$unit" "$fake/etc/systemd/system/pc-oc-gpu.service"
  printf '#!/usr/bin/bash\n' >"$fake/usr/local/lib/pc-oc/pc-oc"
  chmod "$1" "$fake/usr/local/lib/pc-oc/pc-oc"
  run unshare -rmn bash "$BATS_TEST_TMPDIR/guard.sh" \
    systemd-analyze verify --man=no --root="$fake" pc-oc-gpu.service
}

@test "the unit has exactly one ExecStart line: /usr/local/lib/pc-oc/pc-oc apply gpu" {
  only ExecStart 'ExecStart=/usr/local/lib/pc-oc/pc-oc apply gpu'
}

@test "the unit is Type=oneshot" {
  only Type 'Type=oneshot'
}

@test "the unit is WantedBy=multi-user.target and nothing else" {
  only WantedBy 'WantedBy=multi-user.target'
}

@test "the unit has no User line" {
  none User
}

@test "the unit has no ExecStartPre line" {
  none ExecStartPre
}

@test "the unit has no ExecStartPost line" {
  none ExecStartPost
}

@test "the unit has no Environment line of any kind" {
  none '[A-Za-z]*Environment[A-Za-z]*'
}

# a warning leaves the exit status 0, so the output must be empty as well
@test "systemd-analyze verify accepts the unit with no warning, from a fake root and no running systemd" {
  verify_in_fake_root 755
  [ "$status" -eq 0 ] || {
    echo "verify exited $status: $output" >&3
    return 1
  }
  [ -z "$output" ] || {
    echo "verify warned: $output" >&3
    return 1
  }
}

# the proof that the case above reads the fake root and not /usr/local/lib/pc-oc on this PC
@test "systemd-analyze verify rejects the unit when the fake root's ExecStart file is not executable" {
  verify_in_fake_root 644
  [ "$status" -ne 0 ]
  [[ "$output" == *"/usr/local/lib/pc-oc/pc-oc"* ]]
}
