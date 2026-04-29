# NixOS module: claude-code-nix package, settings.json activation,
# Cachix substituter pinning. Wraps `nix-env-lib.claude.mkSettings` so
# the same statusline + agentTeams + effortLevel knobs are exposed as
# NixOS options.
{
  config,
  lib,
  pkgs,
  ...
}@args:

let
  cfg = config.services.claude-code;
  nix-env-lib =
    args.nix-env-lib or (import ../lib {
      nixpkgs = pkgs.path or <nixpkgs>;
      inherit (pkgs) system;
      repoRoot = ../.;
    });

  claudeStatus = nix-env-lib.claude.mkStatusBin {
    installedVersion = cfg.package.version;
    inherit (cfg) versionProbe pathPrefix;
  };

  settingsFile = nix-env-lib.claude.mkSettings {
    statusLineCommand = "${claudeStatus}/bin/nix-env-claude-status";
    inherit (cfg) agentTeams effortLevel skipDangerousPrompt;
  };
in
{
  options.services.claude-code = {
    enable = lib.mkEnableOption "Claude Code with the nix-env statusline + settings";

    package = lib.mkOption {
      type = lib.types.package;
      description = "The claude-code derivation. Typically `claude-code-nix.packages.\${system}.claude-code`.";
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
      ];
      default = "high";
    };

    skipDangerousPrompt = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Skip the `--dangerously-skip-permissions` confirmation prompt.";
    };

    versionProbe = lib.mkOption {
      type = lib.types.nullOr (lib.types.attrsOf lib.types.str);
      default = null;
      example = {
        url = "https://raw.githubusercontent.com/sadjow/claude-code-nix/main/package.nix";
        extract = ''version[[:space:]]*=[[:space:]]*"([^"]+)"'';
      };
      description = "Optional `{ url, extract }` for the statusline's upgrade-available hint.";
    };

    pathPrefix = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/workspaces/*";
      description = "Glob for paths that should render as `<first>/.../<leaf>` (devcontainer workspaces).";
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
  };
}
