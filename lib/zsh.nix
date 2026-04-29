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
}:

let
  # Raw values — used both by `mkShellRc` below and by NixOS modules that
  # want to splice individual pieces into `programs.zsh.*` options.
  syntaxHighlightStyles = {
    command = "fg=#89b4fa";
    builtin = "fg=#89b4fa";
    alias = "fg=#a6e3a1";
    function = "fg=#89b4fa";
    path = "fg=#f9e2af,underline";
    globbing = "fg=#f5c2e7";
    single-quoted-argument = "fg=#a6e3a1";
    double-quoted-argument = "fg=#a6e3a1";
    dollar-quoted-argument = "fg=#a6e3a1";
    comment = "fg=#6c7086";
    arg0 = "fg=#89b4fa";
    unknown-token = "fg=#f38ba8";
  };

  autosuggestStyle = "fg=#6c7086";

  historyOpts = {
    histSize = 10000;
    saveSize = 10000;
    setOptions = [
      "SHARE_HISTORY"
      "HIST_IGNORE_DUPS"
      "HIST_IGNORE_SPACE"
    ];
  };

  detectEnvTypeFn = ''
    _nix_env_type() {
      if [[ -n "''${CODER_WORKSPACE_NAME:-}" ]] || [[ -d /coder ]]; then
        echo coder
      elif [[ -f /.dockerenv ]]; then
        if [[ -d /workspaces ]] && find /workspaces -maxdepth 2 -name .devcontainer -type d 2>/dev/null | grep -q .; then
          echo devcontainer
        else
          echo docker
        fi
      elif [[ -f /sys/class/dmi/id/sys_vendor ]]; then
        local vendor
        vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)
        case "$vendor" in
          *QEMU*|*KVM*|*VMware*|*VirtualBox*|*Xen*|*Microsoft*|*Amazon*|*Google*) echo vm ;;
          *) echo local ;;
        esac
      else
        echo local
      fi
    }
  '';

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
    }:
    let
      configDir = zellij.mkConfigDir { inherit identityFile timezone; };

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

        ${detectEnvTypeFn}
        export NIX_ENV_TYPE="$(_nix_env_type)"
        unset -f _nix_env_type

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
          alias ls='eza'
          alias ll='eza -la --group-directories-first'
          alias la='eza -a'
          alias lt='eza --tree'
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
    historyOpts
    detectEnvTypeFn
    mkShellRc
    mkWrappedZsh
    ;
}
