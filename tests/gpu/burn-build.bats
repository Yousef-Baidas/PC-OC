#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# Contract for gpu/burn.pin and gpu/burn-build.sh (#134, cases 1 to 5 of the ticket's
# Check list). curl and make are recording mocks, first on PATH and bound over
# /usr/bin/<name> in a private mount namespace (fixtures/load/guard.sh), so no case can
# download or build. The tarball is a few bytes packed in setup; sha256sum and tar are real.

load fixtures/load/helper

setup() {
  common_setup
  use_mocks curl make
  export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
  BUILD="$XDG_CACHE_HOME/pc-oc/gpu-burn/$VERSION"
  # the archive GitHub serves has one top directory, gpu-burn-<commit>
  stage="$BATS_TEST_TMPDIR/stage"
  mkdir -p "$stage/good/gpu-burn-$VERSION" "$stage/other/gpu-burn-$VERSION"
  cp "$FIX/gpu-burn-src/"* "$stage/good/gpu-burn-$VERSION/"
  cp "$FIX/gpu-burn-src/"* "$stage/other/gpu-burn-$VERSION/"
  echo "not in the pinned tarball" >"$stage/other/gpu-burn-$VERSION/UNPINNED"
  tar -C "$stage/good" -czf "$stage/good.tar.gz" "gpu-burn-$VERSION"
  tar -C "$stage/other" -czf "$stage/other.tar.gz" "gpu-burn-$VERSION"
  SHA="$(sha256sum "$stage/good.tar.gz" | cut -d' ' -f1)"
  write_pin "$SHA"
  export MOCK_CURL_BODY="$stage/good.tar.gz"
}

# stamps: every stamp file under the cache
stamps() {
  find "$XDG_CACHE_HOME" -name built 2>/dev/null
}

# extracted: every tarball member under the cache or the temp dir
extracted() {
  find "$XDG_CACHE_HOME" "$TMPDIR" \
    \( -name Makefile -o -name gpu_burn-drv.cpp -o -name compare.cu -o -name UNPINNED \) 2>/dev/null
}

# calls <tool>: how many times the mock ran
calls() {
  if [[ -e "$MOCK_STATE/$1.calls" ]]; then wc -l <"$MOCK_STATE/$1.calls"; else echo 0; fi
}

@test "burn.pin: four keys, 40 hex version, url holds the version, 64 hex sha256, source in the manifest (#134 case 1)" {
  mapfile -t pin <"$ROOT/gpu/burn.pin"
  [ "${#pin[@]}" -eq 4 ]
  [[ "${pin[0]}" =~ ^version=[0-9a-f]{40}$ ]]
  [ "${pin[0]}" = "version=3ead140434da9473582b68452f7115967a7a0581" ]
  [ "${pin[1]}" = "url=https://github.com/wilicc/gpu-burn/archive/${pin[0]#version=}.tar.gz" ]
  [[ "${pin[2]}" =~ ^sha256=[0-9a-f]{64}$ ]]
  [ "${pin[3]}" = "source=gpu-burn" ]
  cut -f1 "$ROOT/sources/manifest.tsv" | grep -qxF "${pin[3]#source=}"
}

@test "burn-build: a matching tarball builds, the last line is the directory, the stamp holds the sha256; a second run calls neither curl nor make (#134 case 2)" {
  run --separate-stderr in_ns user "$REPO/gpu/burn-build.sh"
  status_is 0
  [ "${lines[-1]%/}" = "$BUILD" ]
  [ "$(cat "$BUILD/built")" = "$SHA" ]
  [ -f "$BUILD/gpu_burn" ]
  [ -f "$BUILD/compare.fatbin" ]
  curl_calls="$(calls curl)"
  make_calls="$(calls make)"
  [ "$curl_calls" -ge 1 ]
  [ "$make_calls" -ge 1 ]
  grep -qxF "https://github.com/wilicc/gpu-burn/archive/$VERSION.tar.gz" "$MOCK_STATE/curl.args"

  run --separate-stderr in_ns user "$REPO/gpu/burn-build.sh"
  status_is 0
  [ "${lines[-1]%/}" = "$BUILD" ]
  [ "$(calls curl)" -eq "$curl_calls" ]
  [ "$(calls make)" -eq "$make_calls" ]
}

@test "burn-build: sha256 mismatch exits 1 with nothing extracted, make not called, the download deleted, no stamp (#134 case 3)" {
  # a well-formed tarball that is not the pinned one: extracting it would succeed
  export MOCK_CURL_BODY="$stage/other.tar.gz"
  run --separate-stderr in_ns user "$REPO/gpu/burn-build.sh"
  status_is 1
  [ "$(calls curl)" -ge 1 ]
  [ -z "$(extracted)" ]
  [ "$(calls make)" -eq 0 ]
  [ ! -e "$(cat "$MOCK_STATE/curl.out")" ]
  [ -z "$(find "$XDG_CACHE_HOME" -type f 2>/dev/null)" ]
  [ -z "$(stamps)" ]
}

@test "burn-build: make failing exits 1 and leaves no stamp (#134 case 4)" {
  MOCK_MAKE=fail run --separate-stderr in_ns user "$REPO/gpu/burn-build.sh"
  status_is 1
  [ "$(calls make)" -ge 1 ]
  [ -z "$(stamps)" ]
}

@test "burn-build: make succeeding without a gpu_burn exits 1 and leaves no stamp (#134 case 4)" {
  MOCK_MAKE=no-binary run --separate-stderr in_ns user "$REPO/gpu/burn-build.sh"
  status_is 1
  [ "$(calls make)" -ge 1 ]
  [ -z "$(stamps)" ]
}

@test "burn-build: uid 0 is refused and curl is not called (#134 case 5)" {
  run --separate-stderr in_ns root "$REPO/gpu/burn-build.sh"
  status_is 1
  [ "$stderr" = "pc-oc: gpu: burn-build: run it as your own user, not root" ]
  no_tool_ran
}

@test "burn-build: a pin whose url names another host is refused and curl is not called (#134 case 5)" {
  write_pin "$SHA" "https://github.com.mirror.example/wilicc/gpu-burn/archive/$VERSION.tar.gz"
  run --separate-stderr in_ns user "$REPO/gpu/burn-build.sh"
  status_is 1
  [[ "$stderr" == "pc-oc: gpu: "* ]]
  no_tool_ran
  [ -z "$(stamps)" ]
}

# Cases beyond the contract (#134): the readings of amendment 1 ruling 8 and the choices
# gpu/burn-build.sh makes where the ticket is silent.

@test "burn-build: curl is held to https on every hop and fails on an HTTP error; make gets CUDAPATH=/opt/cuda in the build directory (#134)" {
  run --separate-stderr in_ns user "$REPO/gpu/burn-build.sh"
  status_is 0
  args="$(tr '\n' ' ' <"$MOCK_STATE/curl.args")"
  [[ "$args" == *"--proto =https "* ]]
  [[ "$args" == *"--proto-redir =https "* ]]
  [[ "$args" == *"--fail "* ]]
  grep -qxF "arg CUDAPATH=/opt/cuda" "$MOCK_STATE/make.env"
  [ "$(cat "$MOCK_STATE/make.cwd")" = "$(cd "$BUILD" && pwd -P)" ]
  # stdout is the directory and nothing else
  [ "$output" = "$BUILD" ]
}

@test "burn-build: a failed download exits 1, make is not called, nothing is left in the cache (#134)" {
  MOCK_CURL_RC=22 run --separate-stderr in_ns user "$REPO/gpu/burn-build.sh"
  status_is 1
  [ "$(calls curl)" -ge 1 ]
  [ "$(calls make)" -eq 0 ]
  [ -z "$(find "$XDG_CACHE_HOME" -type f 2>/dev/null)" ]
}

@test "burn-build: a build whose stamp is not the pin's sha256 is removed and built again (#134)" {
  mkdir -p "$BUILD"
  echo "left over" >"$BUILD/stale"
  : >"$BUILD/compare.fatbin"
  cp "$FIX/mocks/make" "$BUILD/gpu_burn"
  sha256sum "$FIX/gpu-burn-src/compare.cu" | cut -d' ' -f1 >"$BUILD/built"
  run --separate-stderr in_ns user "$REPO/gpu/burn-build.sh"
  status_is 0
  [ "$(calls curl)" -eq 1 ]
  [ "$(calls make)" -eq 1 ]
  [ "$(cat "$BUILD/built")" = "$SHA" ]
  [ ! -e "$BUILD/stale" ]
}

@test "burn-build: an argument exits 2 and no tool runs (#134)" {
  run --separate-stderr in_ns user "$REPO/gpu/burn-build.sh" --force
  status_is 2
  [ -z "$output" ]
  no_tool_ran
}

@test "burn-build: no HOME and no XDG_CACHE_HOME, or a pin that is not well formed, exits 1 and no tool runs (#134)" {
  HOME="" XDG_CACHE_HOME="" run --separate-stderr in_ns user "$REPO/gpu/burn-build.sh"
  status_is 1
  no_tool_ran
  write_pin abc
  run --separate-stderr in_ns user "$REPO/gpu/burn-build.sh"
  status_is 1
  [[ "$stderr" == "pc-oc: gpu: burn-build: burn.pin: "* ]]
  no_tool_ran
}
