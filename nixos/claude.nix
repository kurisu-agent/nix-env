# NixOS module: claude-code-nix package, settings.json activation,
# Cachix substituter pinning. Wraps `nix-env-lib.claude.mkSettings` so
# the same statusline + agentTeams + effortLevel knobs are exposed as
# NixOS options.
{
  config,
  lib,
  pkgs,
  claude-code-nix,
  ...
}@args:

let
  cfg = config.services.claude-code;
  nix-env-lib =
    if cfg.paletteOverride == { } then
      args.nix-env-lib or (import ../lib {
        nixpkgs = pkgs.path or <nixpkgs>;
        inherit (pkgs) system;
        repoRoot = ../.;
      })
    else
      import ../lib {
        nixpkgs = pkgs.path or <nixpkgs>;
        inherit (pkgs) system;
        repoRoot = ../.;
        inherit (cfg) paletteOverride;
      };

  claudeStatus = nix-env-lib.claude.mkStatusBin {
    installedVersion = cfg.package.version;
    inherit (cfg) versionProbe effortLevel;
  };

  settingsFile = nix-env-lib.claude.mkSettings {
    statusLineCommand = "${claudeStatus}/bin/nix-env-claude-status";
    inherit (cfg) agentTeams effortLevel skipDangerousPrompt;
  };
in
{
  options.services.claude-code = {
    enable = lib.mkEnableOption "Claude Code with the nix-env statusline + settings";

    paletteOverride = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { accent = "#FF0099"; };
      description = ''
        Partial-merge palette override applied to lib/palette.nix.
        Affects the rendered statusline ANSI escapes (path, branch,
        added/modified/deleted counters). See
        `services.zellij.paletteOverride` for naming details.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = claude-code-nix.packages.${pkgs.stdenv.hostPlatform.system}.claude-code;
      defaultText = lib.literalExpression "claude-code-nix.packages.\${system}.claude-code";
      description = ''
        The claude-code derivation. Defaults to the
        `claude-code-nix` flake input pinned by nix-env (the
        sadjow/claude-code-nix fork tracks upstream npm releases more
        aggressively than nixpkgs). Override only if you want a
        specific build.
      '';
    };

    agentTeams = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 in settings.json env.";
    };

    effortLevel = lib.mkOption {
      type = lib.types.enum [
        "low"
        "medium"
        "high"
        "xhigh"
        "max"
      ];
      default = "high";
      description = ''
        Reasoning effort baked into both settings.json and the statusline
        glyph. Note: "max" isn't in upstream's settings.json schema enum
        (anthropics/claude-code#52247) and is officially session-only —
        but the CLI still writes it via /effort, so it's included here.
      '';
    };

    skipDangerousPrompt = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Skip the `--dangerously-skip-permissions` confirmation prompt.";
    };

    versionProbe = lib.mkOption {
      type = lib.types.nullOr (lib.types.attrsOf lib.types.str);
      default = {
        url = "https://raw.githubusercontent.com/sadjow/claude-code-nix/main/package.nix";
        extract = ''version[[:space:]]*=[[:space:]]*"([^"]+)"'';
      };
      defaultText = lib.literalExpression ''
        {
          url = "https://raw.githubusercontent.com/sadjow/claude-code-nix/main/package.nix";
          extract = ''''version[[:space:]]*=[[:space:]]*"([^"]+)"'''';
        }
      '';
      description = ''
        `{ url, extract }` for the statusline's "upgrade available"
        hint — defaults to the same `claude-code-nix` source the
        package itself comes from. Set to `null` to disable polling.
      '';
    };

    cachix = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Wire `claude-code.cachix.org` into `nix.settings.substituters`
        with its trusted-public-key. Avoids compiling the node-based
        bundle from source on cold cache miss. Disable on hosts that
        must not pull from third-party caches.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      cfg.package
      pkgs.gh
      pkgs.tmux
    ];

    system.userActivationScripts.nixEnvClaudeSettings.text = ''
      mkdir -p "$HOME/.claude"
      install -m 0644 ${settingsFile} "$HOME/.claude/settings.json"
    '';

    environment.interactiveShellInit = ''
      alias yolo='claude --dangerously-skip-permissions'
    '';

    nix.settings = lib.mkIf cfg.cachix {
      substituters = [ "https://claude-code.cachix.org" ];
      trusted-public-keys = [
        "claude-code.cachix.org-1:YeXf2aNu7UTX8Vwrze0za1WEDS+4DuI2kVeWEE4fsRk="
      ];
    };
  };
}
