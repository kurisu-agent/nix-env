{
  description = "nix-env — shared zellij + claude + omp + eza + zsh configuration (Catppuccin Mocha)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # sadjow/claude-code-nix tracks upstream npm releases more aggressively
    # than nixpkgs. Consumers that already pin claude-code-nix should
    # `inputs.nix-env.inputs.claude-code-nix.follows = "claude-code-nix"`
    # to keep one copy in their lock.
    claude-code-nix = {
      url = "github:sadjow/claude-code-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      claude-code-nix,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems f;

      # Top-level palette override knob. Consumers that want the whole
      # project retinted set this when consuming the flake; flake-level
      # consumers can also re-call mkLib with their own override.
      defaultPaletteOverride = { };

      mkLib =
        system:
        import ./lib {
          inherit nixpkgs system;
          repoRoot = ./.;
          paletteOverride = defaultPaletteOverride;
        };

      mkLintApps =
        system:
        import ./flake/lint.nix {
          pkgs = nixpkgs.legacyPackages.${system};
        };

      mkUpdateApp =
        system:
        import ./flake/update.nix {
          pkgs = nixpkgs.legacyPackages.${system};
        };
    in
    {
      lib = forAllSystems mkLib;

      apps = forAllSystems (
        system:
        let
          lintApps = mkLintApps system;
          updateApp = mkUpdateApp system;
        in
        {
          lint = {
            type = "app";
            program = "${lintApps.lint}/bin/nix-lint";
          };
          fmt = {
            type = "app";
            program = "${lintApps.fmt}/bin/nix-fmt";
          };
          update = {
            type = "app";
            program = "${updateApp.nix-env-update}/bin/nix-env-update";
          };
        }
      );

      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          nix-env-lib = mkLib system;
          nix-env-update = (mkUpdateApp system).nix-env-update;
        in
        {
          # Canonical pre-rendered artefacts. Consumers that don't need
          # the lib's customisation knobs can grab these directly.
          nix-env-zellij-config-dir = nix-env-lib.zellij.mkConfigDir { };
          nix-env-zellij-status = nix-env-lib.zellij.statusBin;
          nix-env-zjstatus-wasm = nix-env-lib.zellij.zjstatusWasm;
          nix-env-zellij-permissions = nix-env-lib.zellij.permissionsKdl;

          # Standalone update CLI. Bundled into nix-env-toolkit (so a
          # plain `nix profile install nix-env#nix-env-toolkit` puts it
          # on PATH) and surfaced as a top-level package so consumer
          # flakes (e.g. drift's drift-devtools) can symlinkJoin just
          # the bin without pulling the whole toolkit twice.
          inherit nix-env-update;

          nix-env-omp-theme = nix-env-lib.ompTheme;
          nix-env-eza-theme = nix-env-lib.ezaTheme;

          # nix-env-toolkit bundles everything a shell session needs into
          # a single `nix profile install` target. Wrapped zellij + zsh
          # honour our config without overwriting the user's `~/.zshrc` /
          # `~/.config/zellij/`. The shellRc tree is staged at
          # `share/nix-env/` so the wrappers can reference it via absolute
          # store path. Upstream zsh plugins, eza, oh-my-posh, fzf, and the
          # apt-set tools come along so the shellRc actually finds what it
          # tries to source. Drift-specific goods (claude-code itself,
          # drift-update) are deliberately *not* here — consumer flakes
          # symlinkJoin those on top.
          nix-env-toolkit =
            let
              shellRc = nix-env-lib.zsh.mkShellRc {
                ompThemeJson = nix-env-lib.ompTheme;
              };
              wrappedZellij = nix-env-lib.zellij.mkWrappedBin {
                configDir = "${shellRc}/share/nix-env/zellij";
              };
              wrappedZsh = nix-env-lib.zsh.mkWrappedZsh { inherit shellRc; };
              claudeStatus = nix-env-lib.claude.mkStatusBin {
                # `claude` may be overlaid post-install at a higher
                # priority; read the running version at runtime instead
                # of baking the flake-pinned one in.
                installedVersion = "$(claude --version 2>/dev/null | awk '{print $1}' || printf unknown)";
              };
            in
            pkgs.symlinkJoin {
              name = "nix-env-toolkit";
              paths = [
                shellRc
                wrappedZellij
                wrappedZsh
                nix-env-lib.zellij.statusBin
                claudeStatus
                nix-env-update
              ]
              ++ (with pkgs; [
                # apt-set parity with devtools:2.
                fzf
                git
                curl
                unzip
                tmux
                iproute2
                procps
                jq

                # zsh plugins the rendered zshrc tries to source.
                zsh-autosuggestions
                zsh-syntax-highlighting

                # modern shell tooling the prompt + aliases assume.
                eza
                oh-my-posh
                yazi
                glow
                gh
                btop
              ]);
            };

          default = nix-env-lib.zellij.mkConfigDir { };
        }
      );

      # NixOS modules. Each consumes `_module.args.nix-env-lib` (set by
      # this very attribute via specialArgs in the consumer's flake) and
      # falls back to importing ./lib directly when used standalone.
      #
      # The `{ pkgs, ... }@args` form is load-bearing: NixOS's module
      # system populates a function-style module's args via `functionArgs`,
      # which only sees explicitly-named formals. A bare `args: ...`
      # would be called with the empty special-args set (no `pkgs`, no
      # `config`, no `lib`), which then bombs as soon as the inner
      # module destructures any of those.
      nixosModules =
        let
          mkModule =
            file:
            { pkgs, ... }@args:
            let
              system = pkgs.stdenv.hostPlatform.system;
            in
            import file (
              args
              // {
                nix-env-lib = self.lib.${system};
                # nix-env's own pinned pkgs — used for ABI-coupled
                # binaries like zellij (must match zjstatus.wasm).
                nix-env-pkgs = nixpkgs.legacyPackages.${system};
                inherit claude-code-nix;
              }
            );
        in
        {
          zellij = mkModule ./nixos/zellij.nix;
          zellij-zsh = mkModule ./nixos/zellij-zsh.nix;
          zsh = mkModule ./nixos/zsh.nix;
          claude = mkModule ./nixos/claude.nix;
          cli-tools = mkModule ./nixos/cli-tools.nix;
        };

      # `nix flake check` smoke-tests every output evaluates and the
      # rendered config dir contains the expected files.
      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          nix-env-lib = mkLib system;
          configDir = nix-env-lib.zellij.mkConfigDir { };
        in
        {
          zellij-config-dir-shape = pkgs.runCommand "nix-env-check-zellij-config-dir" { } ''
            cd ${configDir}
            for f in config.kdl themes/catppuccin_mocha.kdl layouts/default.kdl layouts/default.swap.kdl layouts/help.kdl; do
              [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }
            done
            grep -q advanced_mouse_actions config.kdl || { echo "config.kdl missing advanced_mouse_actions" >&2; exit 1; }
            grep -q text_unselected themes/catppuccin_mocha.kdl || { echo "theme uses old format" >&2; exit 1; }
            grep -q quadrants layouts/default.swap.kdl || { echo "swap missing quadrants" >&2; exit 1; }
            grep -q stacked layouts/default.swap.kdl || { echo "swap missing stacked" >&2; exit 1; }
            grep -q '__ZJSTATUS__\|__STATUS_CMD__\|__TIMEZONE__' layouts/default.kdl && {
              echo "default.kdl still has unresolved placeholders" >&2; exit 1;
            } || true
            touch $out
          '';

          nix-env-claude-status-renders = pkgs.runCommand "check-nix-env-claude-status" { } ''
            bin=${nix-env-lib.claude.mkStatusBin { installedVersion = "1.2.3"; }}/bin/nix-env-claude-status
            [ -x "$bin" ] || { echo "nix-env-claude-status not executable" >&2; exit 1; }
            echo '{}' | "$bin" >/dev/null

            # Effort glyph wiring: "high" should emit the MDI circle_slice_5
            # glyph (U+F01AA2) into the rendered statusline.
            effort_bin=${
              nix-env-lib.claude.mkStatusBin {
                installedVersion = "1.2.3";
                effortLevel = "high";
              }
            }/bin/nix-env-claude-status
            rendered=$(echo '{}' | "$effort_bin")
            printf '%s' "$rendered" | grep -qF '󰪢' \
              || { echo "effort glyph missing in rendered output: $rendered" >&2; exit 1; }

            touch $out
          '';
        }
      );
    };
}
