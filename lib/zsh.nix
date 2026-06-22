# Zsh helpers.
#
# Two layers:
#   - Raw values (`syntaxHighlightStyles`, `autosuggestStyle`, `historyOpts`,
#     `detectEnvTypeFn`) that consumers splice into hand-written zsh config.
#   - `mkShellRc` + `mkWrappedZsh` that produce a fully-rendered shellrc
#     tree and a zsh wrapped at `ZDOTDIR`, ready for symlinkJoin into a
#     toolkit derivation.
#
# `mkShellRc` is the structural counterpart to `mkConfigDir` for zellij:
# it bundles the bashrc-bootstrap, the zshrc, and the zellij config tree
# under a single `share/nix-env/` prefix so wrappers can reference one
# absolute store path.
{
  pkgs,
  lib,
  zellij,
  palette,
}:

let
  # Raw values — used both by `mkShellRc` below and by NixOS modules that
  # want to splice individual pieces into `programs.zsh.*` options.
  # Colors are role-mapped (info/accent/warning/error/muted) so retinting
  # the project happens via lib/palette.nix, not here.
  syntaxHighlightStyles = {
    command = "fg=${palette.info}";
    builtin = "fg=${palette.info}";
    alias = "fg=${palette.accent}";
    function = "fg=${palette.info}";
    path = "fg=${palette.warning},underline";
    globbing = "fg=${palette.pink}";
    single-quoted-argument = "fg=${palette.accent}";
    double-quoted-argument = "fg=${palette.accent}";
    dollar-quoted-argument = "fg=${palette.accent}";
    comment = "fg=${palette.muted}";
    arg0 = "fg=${palette.info}";
    unknown-token = "fg=${palette.error}";
  };

  autosuggestStyle = "fg=${palette.muted}";

  # Single source of truth for the eza-backed ls family. Both
  # `mkShellRc` (this file, used by nix-on-droid + the toolkit
  # derivation) and `nixos/zsh.nix` (the NixOS module) consume this
  # attr, so the two paths render the same shell aliases.
  ezaAliases = {
    ls = "eza --icons";
    ll = "eza -la --icons --group-directories-first";
    la = "eza -a --icons";
    lt = "eza --tree --icons";
  };

  historyOpts = {
    histSize = 10000;
    saveSize = 10000;
    setOptions = [
      "SHARE_HISTORY"
      "HIST_IGNORE_DUPS"
      "HIST_IGNORE_SPACE"
    ];
  };

  # mkShellRc renders bashrc-bootstrap + zshrc + a copy of the zellij
  # config tree under a single `share/nix-env/` prefix. The bashrc-bootstrap
  # is the boot script `~/.bashrc` is expected to source; the zshrc is what
  # gets loaded when zsh starts with `ZDOTDIR=$out/share/nix-env/zdotdir`.
  #
  # Args:
  #   ompThemeJson         : derivation | path — the rendered OMP theme.
  #   identityFile         : string — path the bootstrap and topbar read.
  #   timezone             : string — IANA tz string baked into the zellij
  #                          layout (passed through to mkConfigDir).
  #   extraBashrcPrelude   : string — shell snippet inserted into
  #                          bashrc-bootstrap *before* the standard body
  #                          (conntype write, auto-attach, exec zsh).
  #                          Use this to write identity.json from a
  #                          consumer-specific source (drift's info.json,
  #                          for example) and export TZ before the rest
  #                          of the bootstrap runs.
  #   extraZshrc           : string — shell snippet appended to zshrc.
  #                          Use this for consumer-specific aliases.
  mkShellRc =
    {
      ompThemeJson,
      identityFile ? "$HOME/.config/zellij/identity.json",
      timezone ? "",
      extraBashrcPrelude ? "",
      extraZshrc ? "",
      # Inherits the claude-by-default grid command; pass null/[] to opt out.
      gridPaneCommand ? zellij.defaultGridPaneCommand,
    }:
    let
      configDir = zellij.mkConfigDir { inherit identityFile timezone gridPaneCommand; };

      bashrcBootstrap = pkgs.writeText "nix-env-bashrc-bootstrap" ''
        # --- nix-env shell bootstrap ---
        export PATH="$HOME/.nix-profile/bin:$PATH"

        # Bail for non-interactive / probe shells (devcontainer userEnvProbe
        # runs `bash -lic` with no tty).
        [[ ! -t 0 ]] && return 2>/dev/null || :
        [[ -z "''${PS1:-}" ]] && return 2>/dev/null || :

        ${extraBashrcPrelude}

        # Stamp the *current* attach context to /tmp/zellij-conntype on every
        # interactive shell boot. zellij captures env at session-creation
        # time and never refreshes for re-attaches, so reading $SSH_CONNECTION
        # inside a long-lived plugin lies after the next attach.
        if [[ -n "''${MOSH_CONNECTION:-}" ]]; then
          echo mosh > /tmp/zellij-conntype
        elif [[ -n "''${SSH_CONNECTION:-}" ]]; then
          echo ssh > /tmp/zellij-conntype
        elif [[ "''${DEVPOD:-}" == "true" ]]; then
          echo devpod > /tmp/zellij-conntype
        else
          echo local > /tmp/zellij-conntype
        fi

        # Auto-attach zellij on remote sessions (SSH/mosh/devcontainer).
        if [[ $- == *i* ]] && [[ -z "''${ZELLIJ:-}" ]] && command -v zellij >/dev/null 2>&1; then
          if [[ -n "''${SSH_CONNECTION:-}" ]] || [[ -n "''${MOSH_CONNECTION:-}" ]] || [[ "''${DEVPOD:-}" == "true" ]]; then
            export TERM=xterm-256color
            export COLORTERM=truecolor
            if command -v zsh >/dev/null 2>&1; then export SHELL="$(command -v zsh)"; fi
            exec zellij attach main --create --force-run-commands
          fi
        fi

        # Otherwise drop into zsh for local interactive sessions.
        if [[ $- == *i* ]] && [[ -z "''${ZSH_VERSION:-}" ]] && command -v zsh >/dev/null 2>&1; then
          export SHELL="$(command -v zsh)"
          exec zsh
        fi
      '';

      zshrc = pkgs.writeText "nix-env-zshrc" ''
        # Bail on non-interactive zsh (probes, sourced scripts).
        [[ ! -o interactive ]] && return
        [[ -n "''${ZSH_EXECUTION_STRING:-}" ]] && return

        export PATH="$HOME/.nix-profile/bin:$PATH"
        export LANG=en_US.UTF-8
        export LC_ALL=en_US.UTF-8

        HISTFILE=~/.zsh_history
        HISTSIZE=${toString historyOpts.histSize}
        SAVEHIST=${toString historyOpts.saveSize}
        setopt ${lib.concatStringsSep " " historyOpts.setOptions}

        # zsh plugins from the user's nix-profile (the toolkit symlinkJoin
        # delivers them). Best-effort: a missing plugin doesn't error.
        for _ne_plugin in \
          "$HOME/.nix-profile/share/zsh-autosuggestions/zsh-autosuggestions.zsh" \
          "$HOME/.nix-profile/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
        do
          [[ -f "$_ne_plugin" ]] && source "$_ne_plugin"
        done
        unset _ne_plugin

        ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='${autosuggestStyle}'

        typeset -A ZSH_HIGHLIGHT_STYLES
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (k: v: "ZSH_HIGHLIGHT_STYLES[${k}]='${v}'") syntaxHighlightStyles
        )}

        if command -v oh-my-posh >/dev/null 2>&1; then
          eval "$(oh-my-posh init zsh --config ${ompThemeJson})"
        fi

        if command -v eza >/dev/null 2>&1; then
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (k: v: "  alias ${k}='${v}'") ezaAliases
        )}
        else
          alias ll='ls -alF'
        fi

        ${extraZshrc}

        # Personal flair hook: drop a ~/.zshrc.local for character-specific
        # aliases without forking the flake.
        [ -f "$HOME/.zshrc.local" ] && source "$HOME/.zshrc.local"
      '';
    in
    pkgs.runCommand "nix-env-shell-rc"
      {
        passthru = { inherit configDir; };
      }
      ''
        mkdir -p $out/share/nix-env/zdotdir
        install -m 0644 ${bashrcBootstrap} $out/share/nix-env/bashrc-bootstrap
        install -m 0644 ${zshrc}           $out/share/nix-env/zdotdir/.zshrc
        cp -r ${configDir} $out/share/nix-env/zellij
      '';

  # mkWrappedZsh wraps `pkgs.zsh` with `ZDOTDIR` defaulted at the shellRc's
  # zdotdir. `--set-default` leaves a user's existing $ZDOTDIR untouched,
  # so a user who genuinely wants their own zsh setup can still override.
  mkWrappedZsh =
    { shellRc }:
    pkgs.runCommand "zsh-nix-env"
      {
        nativeBuildInputs = [ pkgs.makeWrapper ];
      }
      ''
        mkdir -p $out/bin
        makeWrapper ${pkgs.zsh}/bin/zsh $out/bin/zsh \
          --set-default ZDOTDIR ${shellRc}/share/nix-env/zdotdir
      '';
in
{
  inherit
    syntaxHighlightStyles
    autosuggestStyle
    ezaAliases
    historyOpts
    mkShellRc
    mkWrappedZsh
    ;
}
