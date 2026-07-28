# `nix flake check` smoke tests.
#
# Single source of truth for the checks set — flake.nix just imports this
# per-system, the same way it imports lint.nix and update.nix. Every check
# here is a cheap runCommand or an eval-only lib.evalModules, so the whole
# set costs far less than a VM test; keep it that way.
{
  pkgs,
  lib,
  nix-env-lib,
  # self.nixosModules.cli-tools, passed in rather than reached for, so this
  # file has no handle on the flake's own output attrset.
  cliToolsModule,
}:

let
  configDir = nix-env-lib.zellij.mkConfigDir { };
in
{
  # The rendered config dir contains the expected files, with every
  # build-time placeholder resolved.
  zellij-config-dir-shape = pkgs.runCommand "nix-env-check-zellij-config-dir" { } ''
    cd ${configDir}
    for f in config.kdl themes/catppuccin_mocha.kdl layouts/default.kdl layouts/default.swap.kdl layouts/help.kdl \
             layouts/grid4.kdl layouts/grid6.kdl layouts/grid8.kdl; do
      [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }
    done
    grep -q advanced_mouse_actions config.kdl || { echo "config.kdl missing advanced_mouse_actions" >&2; exit 1; }
    # Every grid keybind must point at a layout file that exists, with
    # __LAYOUTDIR__ resolved. A bad path here is silent at config-load
    # and only shows up as a keypress that does nothing.
    grep -q __LAYOUTDIR__ config.kdl && { echo "config.kdl has unresolved __LAYOUTDIR__" >&2; exit 1; } || true
    for g in 4 6 8; do
      grep -q "layouts/grid$g.kdl" config.kdl || { echo "config.kdl has no keybind for grid$g" >&2; exit 1; }
    done
    # Pane-count per grid: leaf panes are the lines mkGrid emits for
    # gridPaneCommand (default: a `pane command="sh"` per cell).
    for spec in "grid4 4" "grid6 6" "grid8 8"; do
      set -- $spec
      n=$(grep -c '^pane command=' "layouts/$1.kdl")
      [ "$n" = "$2" ] || { echo "$1.kdl has $n panes, expected $2" >&2; exit 1; }
    done
    # grid8 is the TALL one: 4 row containers, each split into 2 cells.
    rows=$(grep -c 'split_direction="vertical"' layouts/grid8.kdl)
    [ "$rows" = 4 ] || { echo "grid8.kdl has $rows rows, expected 4" >&2; exit 1; }
    grep -q text_unselected themes/catppuccin_mocha.kdl || { echo "theme uses old format" >&2; exit 1; }
    grep -q quadrants layouts/default.swap.kdl || { echo "swap missing quadrants" >&2; exit 1; }
    grep -q stacked layouts/default.swap.kdl || { echo "swap missing stacked" >&2; exit 1; }
    grep -q '__ZJSTATUS__\|__STATUS_CMD__\|__TIMEZONE__' layouts/default.kdl && {
      echo "default.kdl still has unresolved placeholders" >&2; exit 1;
    } || true
    touch $out
  '';

  # The zsh auto-attach snippet must export COLORTERM=truecolor, and must
  # do it INSIDE the remote-session guard.
  #
  # Worth a check because getting this wrong produces no error and no log
  # line: every hex nix-env renders is 24-bit, and with COLORTERM unset
  # (ssh never forwards it, mosh forwards only a fixed allowlist) the
  # palette silently degrades to a 256-colour approximation. It surfaces
  # as "the theme looks off on the kart", which is unattributable. A grep
  # is the only thing that notices — and it also pins the ORDERING, since
  # hoisting the export out of the guard would claim truecolour for
  # genuinely 256-colour local terminals.
  zsh-autoattach-snippet =
    let
      zshSnippet = pkgs.writeText "nix-env-zsh-autoattach-snippet" nix-env-lib.zellij.zshAutoattachSnippet;
      bashSnippet = pkgs.writeText "nix-env-bash-autoattach-snippet" nix-env-lib.zellij.bashAutoattachSnippet;
    in
    pkgs.runCommand "check-zsh-autoattach-snippet" { } ''
      # First matching line number, or empty. -F because the guard we
      # match on is literal shell, brackets and parameter expansion.
      #
      # The trailing `|| :` is load-bearing: stdenv's setup runs the
      # build command under `set -e -o pipefail`, so a grep MISS (or the
      # SIGPIPE `head -1` hands it) aborts the whole script right here —
      # at the assignment, before a single diagnostic reaches the log.
      # The check would still fail, but with an EMPTY build log, which is
      # the worst possible failure mode for something whose entire job is
      # to tell you which line moved.
      line() { grep -nF -- "$2" "$1" | head -1 | cut -d: -f1 || :; }

      colorterm=$(line ${zshSnippet} 'export COLORTERM=truecolor')
      [ -n "$colorterm" ] || {
        echo "zshAutoattachSnippet does not export COLORTERM=truecolor" >&2
        cat ${zshSnippet} >&2
        exit 1
      }

      # Ordering IS the assertion: guard < export < exec. Because `line`
      # takes the FIRST match, an export hoisted to snippet top level
      # fails the first comparison rather than sneaking past.
      guard=$(line ${zshSnippet} 'if [[ -z "''${ZELLIJ:-}" ]]')
      attach=$(line ${zshSnippet} 'exec zellij attach')
      [ -n "$guard" ] && [ -n "$attach" ] || {
        echo "zshAutoattachSnippet lost its remote guard or its exec" >&2
        cat ${zshSnippet} >&2
        exit 1
      }
      if [ "$guard" -ge "$colorterm" ] || [ "$colorterm" -ge "$attach" ]; then
        echo "COLORTERM export (line $colorterm) is not inside the remote guard (line $guard) before the exec (line $attach):" >&2
        cat -n ${zshSnippet} >&2
        exit 1
      fi

      # The bash sibling is where this behaviour came from; assert it
      # still has it so the two paths cannot drift apart again — that
      # divergence is the whole reason the zsh path was missing it.
      grep -qF -- 'export COLORTERM=truecolor' ${bashSnippet} || {
        echo "bashAutoattachSnippet lost its COLORTERM export" >&2
        cat ${bashSnippet} >&2
        exit 1
      }

      touch $out
    '';

  # nixos/cli-tools.nix's btop settings + the override surface.
  #
  # Eval-only (lib.evalModules over the real flake module with a
  # one-option stub for environment.systemPackages), so this costs
  # nothing next to a VM test. The assertion that MATTERS is (b): the
  # mkDefault-vs-option-default trap produces a config that evaluates
  # cleanly and still reads correctly in the module source, while a
  # consumer that set one leaf silently loses the other two. Nothing
  # but a merge test catches it.
  cli-tools-btop-conf =
    let
      evalCliTools =
        extra:
        (lib.evalModules {
          modules = [
            cliToolsModule
            # cli-tools only ever writes environment.systemPackages,
            # so stubbing that one option is cheaper (and a tighter
            # assertion) than dragging in the whole NixOS module set.
            {
              options.environment.systemPackages = lib.mkOption {
                type = lib.types.listOf lib.types.package;
                default = [ ];
              };
            }
            { services.cli-tools.enable = true; }
            extra
          ];
          specialArgs = { inherit pkgs; };
        }).config;

      # The wrapped btop is appended last; its wrapper script is where
      # the rendered conf and (outside follow mode) the themes dir are
      # named, so both are in its closure and readable from here.
      btopOf = extra: lib.last (evalCliTools extra).environment.systemPackages;
    in
    pkgs.runCommand "check-cli-tools-btop-conf" { } ''
      conf_of() { sed -n 's|.*--config \([^ ]*\).*|\1|p' "$1/bin/btop"; }
      has() {
        grep -qxF "$2" "$1" || { echo "expected line '$2' in $1:" >&2; cat "$1" >&2; exit 1; }
      }
      hasnt() {
        if grep -q "^$2" "$1"; then
          echo "unexpected key '$2' in $1:" >&2; cat "$1" >&2; exit 1
        fi
      }

      # (a) the values this module now owns, and the `#?` version
      # header that stops btop rewriting the read-only store path.
      bare=$(conf_of ${btopOf { }})
      has "$bare" 'update_ms = 200'
      has "$bare" 'theme_background = False'
      has "$bare" 'color_theme = "catppuccin"'
      head -1 "$bare" | grep -q '^#?.*${pkgs.btop.version}' \
        || { echo "conf line 1 missing btop version ${pkgs.btop.version}: $(head -1 "$bare")" >&2; exit 1; }

      # (b) THE ONE THAT MATTERS. A consumer setting a single leaf must
      # keep the other two; `null` must drop exactly one key.
      one=$(conf_of ${btopOf { services.cli-tools.btop.settings.update_ms = 100; }})
      has "$one" 'update_ms = 100'
      has "$one" 'theme_background = False'
      has "$one" 'color_theme = "catppuccin"'

      unset_conf=$(conf_of ${btopOf { services.cli-tools.btop.settings.color_theme = null; }})
      hasnt "$unset_conf" 'color_theme'
      has "$unset_conf" 'theme_background = False'
      has "$unset_conf" 'update_ms = 200'

      # (c) follow mode must pass NO --themes-dir: btop searches a
      # custom theme dir BEFORE ~/.config/btop/themes, so a baked one
      # shadows the symlink the consumer's light/dark watcher repoints
      # and freezes the toggle with nothing to grep for.
      mocha=${btopOf { }}/bin/btop
      follow=${btopOf { services.cli-tools.variant = "follow"; }}/bin/btop
      grep -qF -- '--themes-dir' "$mocha" \
        || { echo "mocha wrapper is missing --themes-dir" >&2; cat "$mocha" >&2; exit 1; }
      grep -qF -- '--config' "$follow" \
        || { echo "follow wrapper is missing --config" >&2; cat "$follow" >&2; exit 1; }
      if grep -qF -- '--themes-dir' "$follow"; then
        echo "follow wrapper must NOT bake --themes-dir" >&2; cat "$follow" >&2; exit 1
      fi

      # The themes dir must hold the file `color_theme = "catppuccin"`
      # resolves to BY STEM, with the palette actually substituted — an
      # unrendered @pal_@ template loads as a broken theme.
      themes=$(sed -n 's|.*--themes-dir \([^ ]*\).*|\1|p' "$mocha")
      [ -f "$themes/catppuccin.theme" ] \
        || { echo "no catppuccin.theme in $themes" >&2; ls "$themes" >&2; exit 1; }
      # Only the `theme[...]` value lines: btop/theme.theme's own header
      # comment says the word `@pal_NAME@` on purpose.
      if grep -q '^theme\[.*@pal_' "$themes/catppuccin.theme"; then
        echo "unsubstituted palette placeholder in the btop theme:" >&2
        grep -n '^theme\[.*@pal_' "$themes/catppuccin.theme" >&2
        exit 1
      fi

      touch $out
    '';

  claude-statusline-renders = pkgs.runCommand "check-claude-statusline" { } ''
    bin=${nix-env-lib.claude.mkStatusBin { }}/bin/claude-statusline
    [ -x "$bin" ] || { echo "claude-statusline not executable" >&2; exit 1; }
    echo '{}' | "$bin" >/dev/null

    # Effort glyph wiring: "high" should emit the MDI circle_slice_5
    # glyph (U+F01AA2) into the rendered statusline.
    effort_bin=${
      nix-env-lib.claude.mkStatusBin {
        effortLevel = "high";
      }
    }/bin/claude-statusline
    rendered=$(echo '{}' | "$effort_bin")
    printf '%s' "$rendered" | grep -qF '󰪢' \
      || { echo "effort glyph missing in rendered output: $rendered" >&2; exit 1; }

    touch $out
  '';
}
