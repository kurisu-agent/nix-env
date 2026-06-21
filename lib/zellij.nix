# Zellij library — produces a config dir, status binary, zjstatus
# permissions file, and the matching wrapped zellij. Repo root is passed
# in so the .kdl / .sh sources can be found regardless of how this module
# is imported.
#
# Color templating: the source files under zellij/ are *templates* with
# `@pal_NAME@` (hex), `@pal_NAME_rgb@` (space-separated RGB), and
# `@pal_NAME_rgb_csv@` (semicolon-separated RGB) placeholders, where
# NAME is any key in the palette (Catppuccin name or role alias). They
# render against the (possibly overridden) palette before being baked
# into the config dir / shell-application binary.
{
  pkgs,
  lib,
  repoRoot,
  palette,
  paletteHelpers,
}:

let
  inherit (paletteHelpers) substitutePalette paletteSedArgs;

  zjstatusVersion = lib.removeSuffix "\n" (builtins.readFile (repoRoot + "/zellij/zjstatus-version"));

  zjstatusWasm = pkgs.fetchurl {
    url = "https://github.com/dj95/zjstatus/releases/download/v${zjstatusVersion}/zjstatus.wasm";
    hash = "sha256-4AaQEiNSQjnbYYAh5MxdF/gtxL+uVDKJW6QfA/E4Yf8=";
  };

  # Bare permissions.kdl ready for `~/.cache/zellij/permissions.kdl`. Both
  # the wrapped-binary first-run path and the NixOS activation script use
  # this same artifact so consumers can't diverge out of sync.
  permissionsKdl = pkgs.writeText "nix-env-zellij-permissions.kdl" ''
    "${zjstatusWasm}" {
        ChangeApplicationState
        RunCommands
        ReadApplicationState
    }
  '';

  # status.sh is a template — palette placeholders are resolved at
  # build time so the rendered binary contains literal hex values
  # (no runtime substitution needed). Tests render the same template
  # at setup() to keep raw bats execution working.
  defaultStatusBin = pkgs.writeShellApplication {
    name = "nix-env-zellij-status";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
      gnugrep
      iproute2
      procps
      jq
      inetutils
    ];
    text = substitutePalette (builtins.readFile (repoRoot + "/zellij/status.sh"));
  };

  # Theme is also a template — RGB triples come from palette so retinting
  # the project (e.g. paletteOverride in mkLib) re-renders the theme.
  themeKdl = pkgs.writeText "nix-env-zellij-theme.kdl" (
    substitutePalette (builtins.readFile (repoRoot + "/zellij/themes/catppuccin_mocha.kdl"))
  );

  # mkConfigDir produces a derivation suitable as `ZELLIJ_CONFIG_DIR`.
  # Substitutes __ZJSTATUS__ / __STATUS_CMD__ / __TIMEZONE__ *and* the
  # palette placeholders in the layout files. `withHelpLayout` toggles
  # `layouts/help.kdl` (the variant that adds zellij's built-in
  # status-bar plugin at the bottom).
  mkConfigDir =
    {
      identityFile ? "$HOME/.config/zellij/identity.json",
      timezone ? "",
      withHelpLayout ? true,
      statusBin ? defaultStatusBin,
    }:
    let
      sub =
        src:
        pkgs.runCommand "nix-env-zellij-layout" { } ''
          ${pkgs.gnused}/bin/sed \
            -e 's|__ZJSTATUS__|${zjstatusWasm}|g' \
            -e 's|__STATUS_CMD__|${statusBin}/bin/nix-env-zellij-status|g' \
            -e 's|__TIMEZONE__|${timezone}|g' \
            ${paletteSedArgs} \
            ${src} > $out
        '';
      defaultLayout = sub (repoRoot + "/zellij/layouts/default.kdl");
      swapLayout = repoRoot + "/zellij/layouts/default.swap.kdl";
      helpLayout = sub (repoRoot + "/zellij/layouts/help.kdl");
    in
    pkgs.runCommand "nix-env-zellij-config-dir"
      {
        passthru = {
          inherit
            zjstatusWasm
            zjstatusVersion
            statusBin
            identityFile
            ;
        };
      }
      ''
        mkdir -p $out/layouts $out/themes
        install -m 0644 ${repoRoot + "/zellij/config.kdl"}                $out/config.kdl
        install -m 0644 ${themeKdl}                                       $out/themes/catppuccin_mocha.kdl
        install -m 0644 ${defaultLayout}                                  $out/layouts/default.kdl
        install -m 0644 ${swapLayout}                                     $out/layouts/default.swap.kdl
        ${if withHelpLayout then "install -m 0644 ${helpLayout} $out/layouts/help.kdl" else ""}
      '';

  # Wrapped zellij: defaults ZELLIJ_CONFIG_DIR at our config dir AND seeds
  # ~/.cache/zellij/permissions.kdl on first run so the zjstatus topbar
  # plugin loads without an interactive consent prompt. --set-default
  # leaves a user's existing $ZELLIJ_CONFIG_DIR untouched, so a user who
  # genuinely wants their own zellij setup can still override.
  mkWrappedBin =
    {
      configDir ? mkConfigDir { },
    }:
    pkgs.writeShellApplication {
      name = "zellij";
      runtimeInputs = [ pkgs.coreutils ];
      text = ''
        : "''${ZELLIJ_CONFIG_DIR:=${configDir}}"
        export ZELLIJ_CONFIG_DIR

        cache_dir="''${XDG_CACHE_HOME:-$HOME/.cache}/zellij"
        perms="$cache_dir/permissions.kdl"
        if [ ! -f "$perms" ]; then
          mkdir -p "$cache_dir"
          install -m 0644 ${permissionsKdl} "$perms"
        fi

        exec ${pkgs.zellij}/bin/zellij "$@"
      '';
    };

  # Shell snippets — bash and zsh equivalents. Both write /tmp/zellij-conntype
  # on every interactive shell boot so zjstatus reads the *current* attach
  # context (zellij captures env at session-creation time and never refreshes
  # for re-attaches), then auto-attach on remote sessions.
  conntypeWriteSnippet = ''
    if [ -n "''${MOSH_CONNECTION:-}" ]; then
        echo mosh > /tmp/zellij-conntype
    elif [ -n "''${SSH_CONNECTION:-}" ]; then
        echo ssh > /tmp/zellij-conntype
    elif [ "''${DEVPOD:-}" = "true" ]; then
        echo devpod > /tmp/zellij-conntype
    else
        echo local > /tmp/zellij-conntype
    fi
  '';

  zshAutoattachSnippet = ''
    # Detect mosh before zellij starts (PPID is still mosh-server at this point).
    if [[ -z "''${MOSH_CONNECTION:-}" ]] && cat /proc/$PPID/comm 2>/dev/null | grep -q mosh-server; then
        export MOSH_CONNECTION=1
    fi
    ${conntypeWriteSnippet}
    if [[ -z "''${ZELLIJ:-}" ]] && [[ -n "''${SSH_CONNECTION:-}" || -n "''${MOSH_CONNECTION:-}" ]]; then
        # Attach to a live session if one exists; otherwise create a fresh
        # session FROM the two-tab startup layout (tab 1 normal, tab 2 a 2x2
        # grid — see zellij/layouts/default.kdl). `default_layout` can't do
        # this: multi-tab layouts only materialise when passed explicitly with
        # -n, and the bare name "default" resolves to zellij's built-in
        # single-pane layout, so we pass the full config-dir path.
        if [[ "$(zellij list-sessions -n 2>/dev/null | grep -cvE 'EXITED|No active|^$')" -gt 0 ]]; then
            zellij attach -c
        else
            zellij -n "''${ZELLIJ_CONFIG_DIR}/layouts/default.kdl"
        fi
    fi
  '';

  bashAutoattachSnippet = ''
    ${conntypeWriteSnippet}
    if [[ $- == *i* ]] && [[ -z "''${ZELLIJ:-}" ]] && command -v zellij >/dev/null 2>&1; then
        if [[ -n "''${SSH_CONNECTION:-}" ]] || [[ -n "''${MOSH_CONNECTION:-}" ]] || [[ "''${DEVPOD:-}" == "true" ]]; then
            export TERM=xterm-256color
            export COLORTERM=truecolor
            exec zellij attach main --create --force-run-commands
        fi
    fi
  '';
in
{
  statusBin = defaultStatusBin;
  inherit
    zjstatusVersion
    zjstatusWasm
    permissionsKdl
    mkConfigDir
    mkWrappedBin
    conntypeWriteSnippet
    zshAutoattachSnippet
    bashAutoattachSnippet
    ;
}
