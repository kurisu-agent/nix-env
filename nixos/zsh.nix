# NixOS module: full zsh setup mirroring the toolkit's `mkShellRc`,
# but driven through `programs.zsh.*` so it composes with other NixOS
# modules. Pulls history opts, syntax-highlight styles, and the
# autosuggest style straight out of `lib/zsh.nix` so the toolkit and
# this module can't drift.
#
# Optional integrations:
#   - `programs.fzf` keybindings + fuzzy completion (default on).
#   - When `services.zellij.enable = true`, the zellij autoattach +
#     conntype-write snippet is spliced into `programs.zsh.interactiveShellInit`
#     so SSH/mosh sessions auto-attach and `/tmp/zellij-conntype` is
#     refreshed on every shell boot. (Equivalent to enabling
#     `nixosModules.zellij-zsh` — kept in this module so consumers don't
#     have to wire two modules.)
#
#   imports = [ inputs.nix-env.nixosModules.zsh ];
#   services.zsh.enable = true;
{
  config,
  lib,
  pkgs,
  ...
}@args:

let
  cfg = config.services.zsh;

  nix-env-lib =
    args.nix-env-lib or (import ../lib {
      nixpkgs = pkgs.path or <nixpkgs>;
      inherit (pkgs) system;
      repoRoot = ../.;
    });

  zshLib = nix-env-lib.zsh;
  zellijLib = nix-env-lib.zellij;

  ompTheme = pkgs.runCommand "nix-env-omp-theme.json" { } ''
    install -m 0644 ${../omp/theme.json} $out
  '';
in
{
  options.services.zsh = {
    enable = lib.mkEnableOption "zsh with the nix-env shared config (Catppuccin OMP, plugins, eza theme, fzf)";

    fzfIntegration = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Wire `programs.fzf.{keybindings, fuzzyCompletion}` so Ctrl-T /
        Ctrl-R / Alt-C and `**<TAB>` work in interactive shells.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Some hosts ship a default `~/.zshrc` from skel that triggers zsh's
    # new-user setup wizard on first login (NixOS-managed config notwithstanding).
    # Touching the file no-ops past that prompt.
    system.userActivationScripts.nixEnvZshrc.text = ''
      test -f "$HOME/.zshrc" || touch "$HOME/.zshrc"
    '';

    programs.zsh = {
      enable = true;
      inherit (zshLib.historyOpts) histSize;
      inherit (zshLib.historyOpts) setOptions;

      autosuggestions = {
        enable = true;
        highlightStyle = zshLib.autosuggestStyle;
      };

      syntaxHighlighting = {
        enable = true;
        styles = zshLib.syntaxHighlightStyles;
      };

      promptInit = ''
        eval "$(oh-my-posh init zsh --config ${ompTheme})"
      '';

      interactiveShellInit = ''
        # eza honours $EZA_CONFIG_DIR for theme.yml; LS_COLORS would override it.
        unset LS_COLORS EZA_COLORS
        export EZA_CONFIG_DIR="/etc/xdg/eza"
      ''
      + lib.optionalString config.services.zellij.enable ''

        ${zellijLib.zshAutoattachSnippet}
      ''
      + ''

        # Personal flair hook: drop ~/.zshrc.local for character-specific
        # aliases / overrides without forking the flake.
        [ -f "$HOME/.zshrc.local" ] && source "$HOME/.zshrc.local"
      '';
    };

    programs.fzf = lib.mkIf cfg.fzfIntegration {
      keybindings = true;
      fuzzyCompletion = true;
    };

    environment = {
      # Match the alias set in lib/zsh.nix (used by non-NixOS consumers
      # like nix-on-droid). Keeping the two paths in lockstep so users
      # who switch between them don't lose muscle memory.
      shellAliases = {
        ls = "eza --icons";
        ll = "eza -la --icons --group-directories-first";
        la = "eza -a --icons";
        lt = "eza --tree --icons";
      };

      etc."xdg/eza/theme.yml".source = ../eza/theme.yml;

      systemPackages = with pkgs; [
        oh-my-posh
        eza
        fzf
      ];
    };
  };
}
