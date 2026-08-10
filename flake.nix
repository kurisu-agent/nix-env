{
  description = "nix-env — shared zellij + claude + omp + eza + zsh configuration (Catppuccin Mocha)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Self-updating native Claude Code. nix-env owns the single claude
    # integration point and re-exports this flake's lib + module, so
    # consumers get claude through nix-env rather than wiring it directly.
    nix-claude-drip = {
      url = "github:kurisu-agent/nix-claude-drip";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nix-claude-drip,
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
          # nix-env's claude lib is re-exported from nix-claude-drip.
          claudeLib = nix-claude-drip.lib.${system};
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

      mkChecks =
        system:
        import ./flake/checks.nix {
          inherit (nixpkgs) lib;
          pkgs = nixpkgs.legacyPackages.${system};
          nix-env-lib = mkLib system;
          cliToolsModule = self.nixosModules.cli-tools;
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
          inherit (mkUpdateApp system) nix-env-update;
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
              # claude statusline from the re-exported drip lib. The launcher
              # + updater stay consumer-side (symlinkJoin'd on top), same as
              # the claude binary always has been. drip's statusline reads the
              # running version from session stdin, so no installedVersion arg.
              claudeStatus = nix-env-lib.claude.mkStatusBin { };
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

          # Re-export drip's pinned herdr, for the same reason `nixosModules.claude`
          # re-exports drip's module: consumers take the agent-workstation tooling
          # from nix-env and never pin it themselves. Deliberately NOT in
          # nix-env-toolkit — herdr is a heavy rust+zig build, and a plain shell
          # session does not need a workspace manager to come with it.
          herdr = nix-claude-drip.packages.${system}.herdr;

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
              inherit (pkgs.stdenv.hostPlatform) system;
            in
            import file (
              args
              // {
                nix-env-lib = self.lib.${system};
                # nix-env's own pinned pkgs — used for ABI-coupled
                # binaries like zellij (must match zjstatus.wasm).
                nix-env-pkgs = nixpkgs.legacyPackages.${system};
              }
            );
        in
        {
          zellij = mkModule ./nixos/zellij.nix;
          zellij-zsh = mkModule ./nixos/zellij-zsh.nix;
          zsh = mkModule ./nixos/zsh.nix;
          # Re-export drip's NixOS module as nix-env's claude module, so
          # consumers `imports = [ nix-env.nixosModules.claude ]` and get the
          # self-updating drip claude (services.claude-code.*).
          claude = nix-claude-drip.nixosModules.default;
          # …and drip's release cache (`services.claude-code-cache.*`), a
          # pull-through HTTP cache in front of the release channel so a fleet
          # pulls each ~262 MiB version across the WAN once instead of once per
          # machine. SEPARATE from `claude` on purpose, exactly as drip keeps
          # them separate: this one is for whichever host serves the cache, and
          # importing it brings an nginx option surface a client machine has no
          # use for. A client opts in by pointing
          # `services.claude-code.releaseBase` at the cache's address.
          claude-cache = nix-claude-drip.nixosModules.cache;
          cli-tools = mkModule ./nixos/cli-tools.nix;
        };

      # `nix flake check` smoke-tests every output evaluates, the rendered
      # config dir has the expected shape, and the shell snippets keep the
      # invariants that fail silently. Definitions live in flake/checks.nix.
      checks = forAllSystems mkChecks;
    };
}
