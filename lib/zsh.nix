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
  hexToRgbCsv,
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

  # zsh ships no ctrl/alt-arrow bindings, so zle matches the `^[[` prefix,
  # fails, and self-inserts the tail — ctrl+left literally types `;5D`.
  #
  # ctrl+backspace arrives as ^H in terminals that send ^? for plain
  # backspace; the default emacs keymap has ^H as backward-delete-char,
  # so it only ate one character instead of the word.
  #
  # home/end: zle knows the app-cursor-mode forms (^[OH / ^[OF) but not
  # the CSI (^[[H) or vt220 (^[[1~) forms, so the keys work or die
  # depending on which mode the terminal/multiplexer happens to be in.
  keyBindings = {
    "^[[1;5C" = "forward-word";
    "^[[1;5D" = "backward-word";
    "^[[1;3C" = "forward-word";
    "^[[1;3D" = "backward-word";
    "^H" = "backward-kill-word";
    "^[[3;5~" = "kill-word";
    "^[[3;3~" = "kill-word";
    "^[[H" = "beginning-of-line";
    "^[[1~" = "beginning-of-line";
    "^[[F" = "end-of-line";
    "^[[4~" = "end-of-line";
  };

  # zsh's default WORDCHARS counts `-` `.` `/` `=` as part of a word, so
  # word motion skips whole paths and kebab-case names. `_` stays in, to
  # keep snake_case identifiers atomic.
  wordChars = "*?_[]~&;!#$%^(){}<>";

  keyBindingsRc = ''
    WORDCHARS='${wordChars}'

  ''
  + lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "bindkey '${k}' ${v}") keyBindings);

  # Tab completion. Stock zsh inserts the common prefix, beeps, and dumps
  # a bare list — with a dozen `Screenshot-2026-…` files you end up typing
  # the tail by hand. fzf-tab swaps the list for an fzf selector: arrows /
  # Tab move, typing narrows, Enter accepts, `/` accepts a directory and
  # keeps completing inside it, `<` `>` switch groups (files vs options).
  # The right-hand pane previews the highlighted item — images through
  # chafa, text through bat, directories as an eza listing.
  #
  # `menu no` is fzf-tab's requirement: zsh's own menu must stay out of the
  # way so the plugin can capture the unambiguous prefix. The matcher makes
  # the prefix case-insensitive and lets `scr-9` reach `Screenshot-2026-09-…`
  # across the `-`/`.`/`_` boundaries. The descriptions format is what
  # fzf-tab reads to group matches; it ignores escape sequences there, so
  # the colour lives in the fzf palette flags instead.
  #
  # `compinit` is the caller's job — NixOS's programs.zsh runs it before
  # interactiveShellInit; mkShellRc below runs its own. fzf-tab must load
  # after it and before the widget-wrapping plugins (autosuggestions,
  # syntax-highlighting), which is why the NixOS module splices the source
  # line in with mkBefore.
  #
  # The list colours are truecolor SGR (38;2 / 48;2) from the palette, not
  # LS_COLORS — the rc unsets LS_COLORS so eza's theme.yml wins, and there is
  # nothing else to inherit from. fzf-tab's ls-colors shim reads the same
  # zstyle to tint its candidate list.
  completionColors = lib.concatStringsSep ":" [
    "di=38;2;${hexToRgbCsv palette.directory}"
    "ln=38;2;${hexToRgbCsv palette.info}"
    "ex=38;2;${hexToRgbCsv palette.accent}"
  ];

  fzfColors = lib.concatStringsSep "," [
    "bg+:${palette.bg_selection}"
    "fg+:${palette.primary}"
    "hl:${palette.accent}"
    "hl+:${palette.accent}"
    "pointer:${palette.accent}"
    "marker:${palette.accent}"
    "spinner:${palette.accent}"
    "prompt:${palette.info}"
    "info:${palette.muted}"
    "header:${palette.muted}"
    "border:${palette.muted}"
    "gutter:-1"
  ];

  # Preview for the fzf-tab pane. fzf-tab exports `realpath` (only for
  # path completions), `word`, `desc` and `group` into the command's
  # environment, so the script takes no args. Images go through chafa:
  # the kitty graphics protocol where the terminal is known to speak it
  # and nothing in between will eat it (zellij and mosh both drop it),
  # unicode block art everywhere else. Runtime deps are pinned via
  # runtimeInputs so the rc can reference the script by store path
  # instead of hoping bat/chafa are on the user's PATH.
  previewBin = pkgs.writeShellApplication {
    name = "nix-env-preview";
    runtimeInputs = with pkgs; [
      bat
      chafa
      coreutils
      eza
      file
    ];
    text = ''
      p="''${realpath:-}"
      if [ -z "$p" ]; then
        printf '%s\n' "''${desc:-''${word:-}}"
        exit 0
      fi
      if [ -d "$p" ]; then
        eza -la --icons --color=always --group-directories-first -- "$p" | head -n 200
        exit 0
      fi
      [ -f "$p" ] || exit 0
      mime=$(file -Lb --mime-type -- "$p")
      case "$mime" in
        image/*)
          fmt=symbols
          if [ -z "''${ZELLIJ:-}" ] && [ -z "''${MOSH_CONNECTION:-}" ] \
             && { [ "''${TERM_PROGRAM:-}" = ghostty ] || [ -n "''${KITTY_WINDOW_ID:-}" ] || [ "''${TERM:-}" = xterm-kitty ]; }; then
            fmt=kitty
          fi
          chafa -f "$fmt" --animate off \
            -s "''${FZF_PREVIEW_COLUMNS:-80}x''${FZF_PREVIEW_LINES:-24}" -- "$p"
          ;;
        text/*|application/json|application/javascript|application/xml|application/toml|application/x-shellscript|inode/x-empty)
          bat --color=always --style=numbers --line-range=:300 -- "$p"
          ;;
        *)
          file -Lb -- "$p"
          ;;
      esac
    '';
  };

  fzfTabPlugin = "${pkgs.zsh-fzf-tab}/share/fzf-tab/fzf-tab.plugin.zsh";

  # Source line only — split from the styles so the NixOS module can pin it
  # ahead of the other plugins with mkBefore while the styles ride along
  # with the rest of the rc. Order between styles and source doesn't matter.
  fzfTabSourceRc = ''
    source ${fzfTabPlugin}
  '';

  completionRc = ''
    zstyle ':completion:*' menu no
    zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=*'
    zstyle ':completion:*' group-name ""
    zstyle ':completion:*' list-dirs-first true
    zstyle ':completion:*' squeeze-slashes true
    zstyle ':completion:*' list-colors '${completionColors}'
    zstyle ':completion:*:descriptions' format '[%d]'
    zstyle ':completion:*:warnings' format '%F{${palette.error}}no matches%f'
    zstyle ':completion:*:git-checkout:*' sort false
    zstyle ':completion:*' use-cache on
    zstyle ':completion:*' cache-path "''${XDG_CACHE_HOME:-$HOME/.cache}/zsh/compcache"

    zstyle ':fzf-tab:*' fzf-command ${pkgs.fzf}/bin/fzf
    zstyle ':fzf-tab:*' fzf-min-height 15
    zstyle ':fzf-tab:*' switch-group '<' '>'
    zstyle ':fzf-tab:*' fzf-flags --color=${fzfColors} --preview-window=right,50%,border-left,wrap --bind=ctrl-/:toggle-preview
    zstyle ':fzf-tab:complete:*:*' fzf-preview '${previewBin}/bin/nix-env-preview'
  '';

  # compinit for rc files that don't get it from the host (mkShellRc; NixOS
  # supplies its own). The dump goes under the cache dir rather than $HOME so
  # a wrapped ZDOTDIR install doesn't litter `~/.zcompdump-*`.
  compinitRc = ''
    fpath=("$HOME/.nix-profile/share/zsh/site-functions" $fpath)
    autoload -Uz compinit
    mkdir -p "''${XDG_CACHE_HOME:-$HOME/.cache}/zsh"
    compinit -d "''${XDG_CACHE_HOME:-$HOME/.cache}/zsh/zcompdump-$ZSH_VERSION"
  '';

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

        ${compinitRc}
        ${completionRc}
        ${fzfTabSourceRc}

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
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "  alias ${k}='${v}'") ezaAliases)}
        else
          alias ll='ls -alF'
        fi

        ${keyBindingsRc}

        # A remote app that dies without cleaning up (dropped ssh/mosh, killed
        # zellij) strands mouse reporting and zellij's kitty keyboard flags in
        # the LOCAL terminal — every mouse move then types an SGR report at the
        # prompt. The process that owed us the reset is gone, so do it here.
        _nix_env_reset_input_modes() {
          printf '\033[?1000l\033[?1002l\033[?1003l\033[?1006l\033[?1015l\033[<u'
        }
        autoload -Uz add-zsh-hook
        add-zsh-hook precmd _nix_env_reset_input_modes

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
    keyBindings
    keyBindingsRc
    completionRc
    compinitRc
    fzfTabSourceRc
    previewBin
    wordChars
    mkShellRc
    mkWrappedZsh
    ;
}
