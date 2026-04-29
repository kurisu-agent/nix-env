#!/usr/bin/env bats
# Shell-level tests for zellij/status.sh — palette resolution, identity
# reading, hostname fallback, conn pill rendering. Run with:
#
#   bats tests/status.bats
#
# Or via Nix without installing bats globally:
#
#   nix shell nixpkgs#bats -c bats tests/status.bats

setup() {
  STATUS_SH="$BATS_TEST_DIRNAME/../zellij/status.sh"
  TMPDIR_LOCAL=$(mktemp -d)
  export NIX_ENV_IDENTITY_FILE="$TMPDIR_LOCAL/identity.json"
  # Neutralise system signals so cases don't depend on the runner's host.
  unset MOSH_CONNECTION SSH_CONNECTION DEVPOD
  rm -f /tmp/zellij-conntype
}

teardown() {
  rm -rf "$TMPDIR_LOCAL"
  rm -f /tmp/zellij-conntype
}

@test "identity: full record renders icon + name in the chosen palette" {
  # Use ASCII '+' as the icon so the test isn't sensitive to multi-byte
  # corruption in editors / pasting / heredocs. status.sh treats any
  # non-empty grapheme the same way.
  cat > "$NIX_ENV_IDENTITY_FILE" <<'JSON'
{ "color": "teal", "name": "neo@dev", "icon": "+" }
JSON
  run bash "$STATUS_SH" identity
  [ "$status" -eq 0 ]
  [[ "$output" == *"#94E2D5"* ]]
  [[ "$output" == *"+ neo@dev"* ]]
}

@test "identity: missing color falls back to overlay0" {
  cat > "$NIX_ENV_IDENTITY_FILE" <<'JSON'
{ "name": "alice" }
JSON
  run bash "$STATUS_SH" identity
  [ "$status" -eq 0 ]
  [[ "$output" == *"#6C7086"* ]]
  [[ "$output" == *"alice"* ]]
}

@test "identity: unknown color falls back to overlay0" {
  cat > "$NIX_ENV_IDENTITY_FILE" <<'JSON'
{ "color": "fuchsia", "name": "alice" }
JSON
  run bash "$STATUS_SH" identity
  [ "$status" -eq 0 ]
  [[ "$output" == *"#6C7086"* ]]
}

@test "identity: missing icon emits no prefix" {
  cat > "$NIX_ENV_IDENTITY_FILE" <<'JSON'
{ "color": "pink", "name": "alice" }
JSON
  run bash "$STATUS_SH" identity
  [ "$status" -eq 0 ]
  [[ "$output" == *"]alice" ]]
}

@test "identity: missing identity file falls back to hostname" {
  rm -f "$NIX_ENV_IDENTITY_FILE"
  run bash "$STATUS_SH" identity
  [ "$status" -eq 0 ]
  expected=$(hostname -s 2>/dev/null || hostname)
  [[ "$output" == *"$expected"* ]]
}

@test "conn_ssh: shows lock when /tmp/zellij-conntype = ssh" {
  echo ssh > /tmp/zellij-conntype
  run bash "$STATUS_SH" conn_ssh
  [ "$status" -eq 0 ]
  [[ "$output" == *""* ]]
}

@test "conn_ssh: shows lock when devpod" {
  echo devpod > /tmp/zellij-conntype
  run bash "$STATUS_SH" conn_ssh
  [ "$status" -eq 0 ]
  [[ "$output" == *""* ]]
}

@test "conn_ssh: silent when local" {
  echo local > /tmp/zellij-conntype
  run bash "$STATUS_SH" conn_ssh
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "conn_mosh: shows wifi glyph when mosh" {
  echo mosh > /tmp/zellij-conntype
  run bash "$STATUS_SH" conn_mosh
  [ "$status" -eq 0 ]
  [[ "$output" == *""* ]]
}

@test "conn_local: shows desktop glyph when local" {
  echo local > /tmp/zellij-conntype
  run bash "$STATUS_SH" conn_local
  [ "$status" -eq 0 ]
  [[ "$output" == *""* ]]
}

@test "fallback: env var when /tmp/zellij-conntype is missing" {
  export SSH_CONNECTION="1.2.3.4 22 5.6.7.8 22"
  run bash "$STATUS_SH" conn_ssh
  [ "$status" -eq 0 ]
  [[ "$output" == *""* ]]
}

@test "unknown field exits non-zero" {
  run bash "$STATUS_SH" not-a-field
  [ "$status" -ne 0 ]
}
