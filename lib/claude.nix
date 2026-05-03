# Claude Code library — produces the canonical `nix-env-claude-status` statusline
# binary and the matching `settings.json` content.
{
  pkgs,
  palette,
  lib,
}:

let
  # MDI circle_slice family rendered as a heat map for the configured
  # effort level. Effort isn't exposed in the statusline stdin JSON
  # (anthropics/claude-code#36187, #31415), so this reflects the *configured*
  # level — not session overrides from `/effort`. RGBs match palette.nix.
  effortGlyphs = {
    low = {
      glyph = "󰪞";
      rgb = "166;227;161";
    }; # 1/8 · green
    medium = {
      glyph = "󰪠";
      rgb = "249;226;175";
    }; # 3/8 · yellow
    high = {
      glyph = "󰪢";
      rgb = "250;179;135";
    }; # 5/8 · peach
    xhigh = {
      glyph = "󰪤";
      rgb = "235;160;172";
    }; # 7/8 · maroon
    max = {
      glyph = "󰪥";
      rgb = "243;139;168";
    }; # 8/8 · red
  };

  # mkStatusBin renders a statusline that reads claude session JSON on
  # stdin and prints a one-line prompt: `<path> <branch> <added> <mod>
  # <del> · <pct>% · [<effort>] <model> · <installed> [→ <latest>]`.
  #
  # Args:
  #   installedVersion : string — what the binary reports as the running
  #                      version. Pass either a fixed Nix-resolved version
  #                      (claude-code-nix.packages.${system}.claude-code.version)
  #                      or the literal string "$(claude --version | awk '{print $1}')"
  #                      to read at runtime, when an overlay may shadow the
  #                      flake-pinned version.
  #   versionProbe     : { url, extract } | null — when set, polls upstream
  #                      once per session (cached per-UID for an hour) and
  #                      appends a "→ <ver>" hint when an upgrade is available.
  #   pathPrefix       : string | null — if non-null, paths matching this
  #                      glob render as `<first>/.../<leaf>` (devcontainer
  #                      workspaces typically use /workspaces/* so the
  #                      prompt mirrors omp's agnoster_short).
  #   effortLevel      : "low" | "medium" | "high" | "xhigh" | "max" | null —
  #                      when non-null, renders an MDI circle-slice glyph
  #                      next to the model name, filled in proportion to the
  #                      level. Should match `mkSettings`'s effortLevel.
  mkStatusBin =
    {
      installedVersion,
      versionProbe ? null,
      pathPrefix ? null,
      effortLevel ? null,
    }:
    let
      effort = if effortLevel == null then null else effortGlyphs.${effortLevel} or null;
    in
    pkgs.writeShellApplication {
      name = "nix-env-claude-status";
      runtimeInputs = with pkgs; [
        coreutils
        jq
        git
        curl
        gnused
        gawk
      ];
      text = ''
        set -u
        input=$(cat)

        # The arg may be a literal version or a runtime command — eval to
        # pick up the latter. Quoted on the LHS so a multi-word literal
        # (unlikely but possible) survives. SC2016 fires because `$(...)`
        # in single quotes doesn't expand, but that's deliberate — the
        # eval below does the expansion.
        # shellcheck disable=SC2016
        installed=${lib.escapeShellArg installedVersion}
        installed=$(eval "printf %s \"$installed\"")

        model=$(printf '%s' "$input"  | jq -r '.model.display_name // "Claude"')
        cwd=$(printf '%s' "$input"    | jq -r '.workspace.current_dir // .cwd // ""')
        pct_raw=$(printf '%s' "$input" | jq -r '.context_window.used_percentage // 0')

        pct=''${pct_raw%%.*}
        [ -z "$pct" ] && pct=0

        model_lc=$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]' | sed -E 's/ ?\(([^)]*) context\)/ \1/')

        # Path shortener mirrors omp's agnoster_short. ${
          if pathPrefix == null then
            "No pathPrefix set, so all paths use ~/HOME or absolute."
          else
            "When the path matches ${pathPrefix}, render `<first>/.../<leaf>`."
        }
        path_for_display() {
          case "$1" in
        ${lib.optionalString (pathPrefix != null) ''
          ${pathPrefix})
            stripped="''${1#/}"
            leaf=$(basename "$1")
            first=$(printf '%s' "$stripped" | cut -d/ -f1)
            seg_count=$(printf '%s' "$stripped" | awk -F/ '{print NF}')
            if [ "$seg_count" -le 2 ]; then
              printf '%s' "$stripped"
            else
              printf '%s/.../%s' "$first" "$leaf"
            fi
            ;;
        ''}
            "$HOME")    printf '~' ;;
            "$HOME"/*)  printf '~%s' "''${1#"$HOME"}" ;;
            *)          printf '%s' "$1" ;;
          esac
        }
        short_cwd=$(path_for_display "$cwd")

        branch=""
        added=0
        modified=0
        deleted=0
        if [ -n "$cwd" ] && [ -d "$cwd" ]; then
          branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
          if [ -n "$branch" ]; then
            while IFS= read -r line; do
              x="''${line:0:1}"; y="''${line:1:1}"
              case "$x$y" in
                "??")          added=$((added+1))  ;;
                "M "|"T ")     modified=$((modified+1)) ;;
                "A "|" A")     added=$((added+1)) ;;
                "D "|" D")     deleted=$((deleted+1)) ;;
                " M"|" T")     modified=$((modified+1)) ;;
                "R "|"C ")     modified=$((modified+1)) ;;
                "UU"|"AA"|"DD"|"AU"|"UA"|"DU"|"UD") deleted=$((deleted+1)) ;;
              esac
            done < <(git -C "$cwd" status --porcelain 2>/dev/null)
          fi
        fi

        RESET=$'\033[0m'
        PINK=$'\033[38;2;245;194;231m'      # ${palette.pink}
        LAVENDER=$'\033[38;2;180;190;254m'  # ${palette.lavender}
        GREEN=$'\033[38;2;166;227;161m'     # ${palette.green}
        YELLOW=$'\033[38;2;249;226;175m'    # ${palette.yellow}
        RED=$'\033[38;2;243;139;168m'       # ${palette.red}
        DIM=$'\033[2m'
        ${lib.optionalString (effort != null) ''
          EFFORT=$'\033[38;2;${effort.rgb}m'
        ''}

        line="''${PINK}''${short_cwd}''${RESET}"
        if [ -n "$branch" ]; then
          line="''${line} ''${LAVENDER} ''${branch}''${RESET}"
          [ "$added"    -gt 0 ] && line="''${line} ''${GREEN}''${added}''${RESET}"
          [ "$modified" -gt 0 ] && line="''${line} ''${YELLOW}''${modified}''${RESET}"
          [ "$deleted"  -gt 0 ] && line="''${line} ''${RED}''${deleted}''${RESET}"
        fi
        line="''${line} ''${DIM}· ''${pct}%''${RESET}"
        ${lib.optionalString (effort != null) ''
          line="''${line} ''${DIM}·''${RESET} ''${EFFORT}${effort.glyph}''${RESET}"
        ''}
        line="''${line} ''${DIM}· ''${model_lc} · ''${installed}''${RESET}"

        ${lib.optionalString (versionProbe != null) ''
          # Shared cache per-UID so a long session sees a newer session's poll
          # result without re-fetching. Each session refreshes at most once per hour.
          shared_cache="/tmp/claude-update-$(id -u)"
          session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)
          session_flag="/tmp/claude-session-''${session_id:-uid$(id -u)}"

          if [ ! -f "$session_flag" ]; then
            touch "$session_flag"
            stale=1
            if [ -f "$shared_cache" ]; then
              now=$(date +%s)
              mtime=$(stat -c %Y "$shared_cache" 2>/dev/null || printf '0')
              [ $((now - mtime)) -lt 3600 ] && stale=0
            fi
            if [ "$stale" = "1" ]; then
              touch "$shared_cache"
              (
                raw=$(curl -sf --max-time 5 ${lib.escapeShellArg versionProbe.url} || true)
                latest=""
                re=${lib.escapeShellArg versionProbe.extract}
                if [[ "$raw" =~ $re ]]; then
                  latest="''${BASH_REMATCH[1]}"
                fi
                : > "$shared_cache"
                if [ -n "$latest" ] && [ "$installed" != "$latest" ]; then
                  newer=$(printf '%s\n%s' "$installed" "$latest" | sort -V | tail -1)
                  if [ "$newer" = "$latest" ]; then
                    printf '→ %s' "$latest" > "$shared_cache"
                  fi
                fi
              ) &
            fi
          fi
          update_msg=$(cat "$shared_cache" 2>/dev/null || true)
          if [ -n "$update_msg" ]; then
            line="''${line} ''${YELLOW}''${update_msg}''${RESET}"
          fi
        ''}

        printf '%s' "$line"
      '';
    };

  # mkSettings renders ~/.claude/settings.json. statusLineCommand should be
  # an absolute path (e.g. "${(mkStatusBin {...})}/bin/nix-env-claude-status").
  mkSettings =
    {
      statusLineCommand,
      agentTeams ? true,
      effortLevel ? "high",
      skipDangerousPrompt ? true,
      padding ? 0,
      extra ? { },
    }:
    pkgs.writeText "nix-env-claude-settings.json" (
      builtins.toJSON (
        {
          skipDangerousModePermissionPrompt = skipDangerousPrompt;
          inherit effortLevel;
          env = lib.optionalAttrs agentTeams {
            CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1";
          };
          statusLine = {
            type = "command";
            command = statusLineCommand;
            inherit padding;
          };
        }
        // extra
      )
    );
in
{
  inherit mkStatusBin mkSettings;
}
