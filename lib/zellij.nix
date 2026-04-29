# Zellij library — produces a config dir, status binary, zjstatus
# permissions file, and the matching wrapped zellij. Repo root is passed
# in so the .kdl / .sh sources can be found regardless of how this module
# is imported.
{
  pkgs,
  lib,
  repoRoot,
}:

let
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
    text = builtins.readFile (repoRoot + "/zellij/status.sh");
  };

  # mkConfigDir produces a derivation suitable as `ZELLIJ_CONFIG_DIR`.
  # Substitutes __ZJSTATUS__ / __STATUS_CMD__ / __TIMEZONE__ in the layout
  # files. `withHelpLayout` toggles `layouts/help.kdl` (the variant that
  # adds zellij's built-in status-bar plugin at the bottom).
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
        install -m 0644 ${repoRoot + "/zellij/themes/catppuccin_mocha.kdl"} $out/themes/catppuccin_mocha.kdl
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
        zellij attach -c
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
