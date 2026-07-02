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

  # Built from source rather than fetching the release wasm: v0.23.0 needs
  # the not-yet-released upstream fix dj95/zjstatus#253 ("use timer events
  # for idle refresh", commit 053898e). Without it the topbar's command
  # widgets stay empty on a fresh session until an external event (resize,
  # mode change, tab switch) forces a repaint — zellij ≥0.44 stopped
  # emitting the incidental per-second SessionUpdate the plugin's render
  # loop leaned on. Drop the patch (and consider returning to the release
  # artifact) once upstream tags a release past 0.23.0. The wasi32 rust
  # toolchain substitutes from cache.nixos.org on x86_64-linux, so this
  # costs one small crate build, not a rustc bootstrap. (On aarch64-linux
  # the cross toolchain is NOT cached upstream and would bootstrap rustc —
  # no current aarch64 consumer uses this lib, but revisit before one
  # does.) $out is the bare .wasm file,
  # exactly like the fetchurl output, so downstream interpolation sites
  # (layouts, permissions.kdl) are unaffected.
  zjstatusWasm = pkgs.pkgsCross.wasi32.rustPlatform.buildRustPackage {
    pname = "zjstatus";
    version = zjstatusVersion;

    src = pkgs.fetchFromGitHub {
      owner = "dj95";
      repo = "zjstatus";
      tag = "v${zjstatusVersion}";
      hash = "sha256-sjMs63OaRhwCrl46v1A+K2EJdqnw63Pc7BMnHqiU790=";
    };

    patches = [ (repoRoot + "/zellij/patches/zjstatus-timer-idle-refresh.patch") ];

    cargoHash = "sha256-jg7EpcA3o/Qdb1eIspZQI3TX3+7gc3YX+FB4l4FZX44=";

    # Tests target the host, not wasm; upstream's own flake skips them too.
    doCheck = false;

    # The cross stdenv wires cargo's linker to the clang wrapper, which
    # rejects the wasm-ld-flavored args rustc emits for wasm targets. Where
    # that wiring lives depends on the consumer's nixpkgs generation: older
    # ones write it into .cargo/config (which a derivation-level env attr
    # outranks), newer ones prefix the hook's cargo invocation with
    # `env CARGO_TARGET_…_LINKER=cc` (which clobbers any env attr). A custom
    # buildPhase sidesteps the hook's invocation entirely, so this export
    # wins on both. wasm-ld runs on the build host.
    buildPhase = ''
      runHook preBuild
      export CARGO_TARGET_WASM32_WASIP1_LINKER=${pkgs.llvmPackages.lld}/bin/wasm-ld
      cargo build -j "$NIX_BUILD_CORES" --release --frozen --target wasm32-wasip1
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      cp target/wasm32-wasip1/release/zjstatus.wasm $out
      runHook postInstall
    '';
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
          col = ''
            pane split_direction="vertical" {
            ${lib.concatStringsSep "\n" (lib.genList (_: gridPaneNode) cols)}
            }'';
        in
        ''
          tab name="grid" {
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
      grid6Layout = mkGrid 2 3 "grid6";
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
        install -m 0644 ${grid6Layout}                                    $out/layouts/grid6.kdl
        ${if withHelpLayout then "install -m 0644 ${helpLayout} $out/layouts/help.kdl" else ""}
      '';

  # Wrapped zellij: defaults ZELLIJ_CONFIG_DIR at our config dir AND keeps
  # ~/.cache/zellij/permissions.kdl seeded so the zjstatus topbar plugin
  # loads without an interactive consent prompt — including after a zjstatus
  # bump changes the wasm store path (grants are keyed by absolute path, so
  # a first-run-only seed would leave upgraded hosts prompting). --set-default
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
        elif ! grep -qF "${zjstatusWasm}" "$perms"; then
          # New wasm path (zjstatus bump): append our grant, preserving any
          # entries the user granted to other plugins. Stale entries for old
          # store paths are harmless.
          cat ${permissionsKdl} >> "$perms"
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
