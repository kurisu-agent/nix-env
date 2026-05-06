#!/usr/bin/env bats
# Shell-level tests for zellij/status.sh — palette resolution, identity
# reading, hostname fallback, conn pill rendering. Run with:
#
#   bats tests/status.bats
#
# Or via Nix without installing bats globally:
#
#   nix shell nixpkgs#bats -c bats tests/status.bats
#
# zellij/status.sh is a template (`@pal_NAME@` placeholders). setup()
# parses lib/palette.nix and substitutes the placeholders into a
# temp-dir copy that each test runs against, mirroring what
# lib/zellij.nix#substitutePalette does at Nix build time. No Nix
# dependency at test time — the parser is pure awk/bash.

# Extract `name = "#hex";` literals first, then resolve `name = base.X;`
# role aliases by looking up the already-loaded Catppuccin name. Sets
# the global PAL associative array.
load_palette() {
    local palette_nix="$1"
    declare -gA PAL=()

    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*([a-zA-Z][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*\"(#[0-9A-Fa-f]+)\"\; ]]; then
            PAL["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
        fi
    done < "$palette_nix"

    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*([a-zA-Z][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*base\.([a-zA-Z][a-zA-Z0-9_]*)\; ]]; then
            local role="${BASH_REMATCH[1]}"
            local target="${BASH_REMATCH[2]}"
            PAL["$role"]="${PAL[$target]}"
        fi
    done < "$palette_nix"
}

# Render a status.sh template against the loaded palette.
render_status_template() {
    local src="$1" dst="$2"
    local sed_args=()
    local name
    for name in "${!PAL[@]}"; do
        sed_args+=( -e "s|@pal_${name}@|${PAL[$name]}|g" )
    done
    sed "${sed_args[@]}" "$src" > "$dst"
}

setup() {
  REPO_ROOT="$BATS_TEST_DIRNAME/.."
  load_palette "$REPO_ROOT/lib/palette.nix"
  STATUS_SH="$BATS_TEST_TMPDIR/status.sh"
  render_status_template "$REPO_ROOT/zellij/status.sh" "$STATUS_SH"
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
  [[ "$output" == *"${PAL[teal]}"* ]]
  [[ "$output" == *"+ neo@dev"* ]]
}

@test "identity: missing color falls back to muted" {
  cat > "$NIX_ENV_IDENTITY_FILE" <<'JSON'
{ "name": "alice" }
JSON
  run bash "$STATUS_SH" identity
  [ "$status" -eq 0 ]
  [[ "$output" == *"${PAL[muted]}"* ]]
  [[ "$output" == *"alice"* ]]
}

@test "identity: unknown color falls back to muted" {
  cat > "$NIX_ENV_IDENTITY_FILE" <<'JSON'
{ "color": "fuchsia", "name": "alice" }
JSON
  run bash "$STATUS_SH" identity
  [ "$status" -eq 0 ]
  [[ "$output" == *"${PAL[muted]}"* ]]
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

@test "user: prints identity.user coloured by identity.color" {
  cat > "$NIX_ENV_IDENTITY_FILE" <<'JSON'
{ "user": "rojo", "color": "lavender" }
JSON
  run bash "$STATUS_SH" user
  [ "$status" -eq 0 ]
  [[ "$output" == *"${PAL[lavender]}"* ]]
  [[ "$output" == *"rojo"* ]]
}

@test "user: silent when identity.user missing" {
  cat > "$NIX_ENV_IDENTITY_FILE" <<'JSON'
{ "name": "kart.alpha" }
JSON
  run bash "$STATUS_SH" user
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "unknown field exits non-zero" {
  run bash "$STATUS_SH" not-a-field
  [ "$status" -ne 0 ]
}

@test "palette: roles resolve to underlying Catppuccin colors" {
  # Sanity check the parser: accent should equal green (per palette.nix
  # role mapping), success should equal teal, etc.
  [ "${PAL[accent]}" = "${PAL[green]}" ]
  [ "${PAL[success]}" = "${PAL[teal]}" ]
  [ "${PAL[warning]}" = "${PAL[yellow]}" ]
  [ "${PAL[error]}" = "${PAL[red]}" ]
  [ "${PAL[muted]}" = "${PAL[overlay0]}" ]
}
