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

  # The grid-tab default: claude in yolo mode. Lives here — the shared floor
  # every consumer (NixOS module, drift/devcontainer via mkShellRc, the flake
  # packages, nix-on-droid) routes through mkConfigDir — so claude-by-default
  # is intrinsic and opt-out (gridPaneCommand = null/[]) is the explicit act,
  # rather than a default that only the NixOS-module path happens to read.
  # Safe everywhere: gridPaneNode runtime-checks the binary and falls back to
  # $SHELL, so hosts without claude get plain shells with no error.
  defaultGridPaneCommand = [
    "claude"
    "--dangerously-skip-permissions"
  ];

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
      # argv list auto-run in every pane of the Ctrl+T grid tabs (g/y). Defaults
      # to claude in yolo mode (see defaultGridPaneCommand); pass null or [] to
      # opt out → plain shells.
      gridPaneCommand ? defaultGridPaneCommand,
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
      # One leaf pane of a grid tab. With gridPaneCommand unset → a plain pane
      # (the user's shell). With it set → a command pane that runtime-checks the
      # binary and runs it, else falls back to $SHELL — so claude-less hosts
      # degrade gracefully instead of erroring. \" is a literal KDL escaped
      # quote ('' strings don't treat backslash specially); ''${ escapes the
      # runtime shell ${...} so Nix leaves it for sh to expand.
      gridPaneNode =
        if gridPaneCommand == null || gridPaneCommand == [ ] then
          "pane"
        else
          let
            bin = builtins.head gridPaneCommand;
            cmdline = lib.concatStringsSep " " gridPaneCommand;
          in
          ''pane command="sh" { args "-c" "command -v ${bin} >/dev/null 2>&1 && exec ${cmdline} || exec \"''${SHELL:-bash}\""; }'';
      # Grid tab KDL (sibling nodes newline-separated — KDL needs that): a
      # `rows`x`cols` grid of gridPaneNode leaves nested in column splits.
      gridTab =
        rows: cols:
        let
          col = ''pane split_direction="vertical" {
${lib.concatStringsSep "\n" (lib.genList (_: gridPaneNode) cols)}
}'';
        in
        ''tab name="grid" {
pane split_direction="horizontal" {
${lib.concatStringsSep "\n" (lib.genList (_: col) rows)}
}
}'';
      # Grid layouts for the Ctrl+T g / y keybinds, generated entirely in Nix:
      # the (already-substituted) default layout's zjstatus topbar template minus
      # its closing brace, then the grid tab, then the layout's closing brace.
      # Keeping the topbar from default.kdl means it never drifts. The tab is
      # passed via an env var so its shell metacharacters (&&, ||, ") and the
      # runtime ''${SHELL} reach the file verbatim.
      mkGrid =
        rows: cols: name:
        pkgs.runCommand "nix-env-zellij-${name}" { gridTabContent = gridTab rows cols; } ''
          ${pkgs.coreutils}/bin/head -n -1 ${defaultLayout} > $out
          printf '%s\n}\n' "$gridTabContent" >> $out
        '';
      grid4Layout = mkGrid 2 2 "grid4";
      grid9Layout = mkGrid 3 3 "grid9";
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
        # config.kdl: bake the absolute layout dir into the Ctrl+T grid keybinds
        # (the keybind loader needs a resolvable path at config-load time; bare
        # layout names and a config-relative layout_dir don't reliably resolve).
        ${pkgs.gnused}/bin/sed "s|__LAYOUTDIR__|$out/layouts|g" \
          ${repoRoot + "/zellij/config.kdl"} > $out/config.kdl
        chmod 0644 $out/config.kdl
        install -m 0644 ${themeKdl}                                       $out/themes/catppuccin_mocha.kdl
        install -m 0644 ${defaultLayout}                                  $out/layouts/default.kdl
        install -m 0644 ${swapLayout}                                     $out/layouts/default.swap.kdl
        install -m 0644 ${grid4Layout}                                    $out/layouts/grid4.kdl
        install -m 0644 ${grid9Layout}                                    $out/layouts/grid9.kdl
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
    defaultGridPaneCommand
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
