# NixOS module: zellij with the shared config dir, zjstatus permissions
# pre-grant (per-user activation, no chown dance), and a shutdown unit.
#
# Imports the per-system nix-env library via `_module.args.nix-env-lib`
# (the flake wires this up). Consumers turn it on with:
#
#   imports = [ inputs.nix-env.nixosModules.zellij ];
#   services.zellij.enable = true;
{
  config,
  lib,
  pkgs,
  ...
}@args:

let
  cfg = config.services.zellij;

  # Resolve the per-system lib. Prefer an explicit `_module.args.nix-env-lib`
  # (set by flake.nix) but fall back to importing it directly so this module
  # is testable in isolation with `nixos-rebuild build-vm`.
  nix-env-lib =
    args.nix-env-lib or (import ../lib {
      nixpkgs = pkgs.path or <nixpkgs>;
      inherit (pkgs) system;
      repoRoot = ../.;
    });

  zellij-lib = nix-env-lib.zellij;

  configDir = zellij-lib.mkConfigDir {
    inherit (cfg) identityFile;
    inherit (cfg) timezone;
    inherit (cfg) withHelpLayout;
  };
in
{
  options.services.zellij = {
    enable = lib.mkEnableOption "Zellij terminal multiplexer with the nix-env shared config";

    identityFile = lib.mkOption {
      type = lib.types.str;
      default = "$HOME/.config/zellij/identity.json";
      description = ''
        Path the topbar reads identity from. JSON with optional fields
        `color` (palette name), `name` (display string), `icon` (single
        grapheme). Writing this file is each consumer's job; the topbar
        falls back to `hostname` when it's missing.
      '';
    };

    timezone = lib.mkOption {
      type = lib.types.str;
      default = config.time.timeZone or "";
      description = "IANA timezone for the topbar clock. Defaults to system time zone.";
    };

    withHelpLayout = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Install layouts/help.kdl (default + bottom built-in status-bar plugin). Pick with `zellij --layout help`.";
    };

    socketDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/tmp/zellij-1000";
      description = ''
        Override `ZELLIJ_SOCKET_DIR` system-wide. Set this on single-user
        hosts to fix the mosh/SSH split-brain (mosh doesn't get
        XDG_RUNTIME_DIR from PAM, so zellij falls back to /tmp while SSH
        uses /run/user). Leave null on multi-user systems.
      '';
    };

    killOnShutdown = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run `zellij kill-all-sessions --yes` from a per-user systemd unit
        on logout. Avoids the 90s cgroup stop-timeout when detached zellij
        servers outlive the user session.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.zellij ];

    environment.variables = {
      ZELLIJ_CONFIG_DIR = "${configDir}";
    }
    // lib.optionalAttrs (cfg.socketDir != null) {
      ZELLIJ_SOCKET_DIR = cfg.socketDir;
    };

    # Pre-grant zjstatus permissions per-user. Runs as the user, so no
    # chown dance is needed (unlike the legacy root-activation pattern
    # that had to mkdir + chown everything afterwards).
    system.userActivationScripts.nixEnvZellijPermissions.text = ''
      mkdir -p "$HOME/.cache/zellij"
      install -m 0644 ${zellij-lib.permissionsKdl} "$HOME/.cache/zellij/permissions.kdl"
    '';

    systemd.user.services = lib.mkIf cfg.killOnShutdown {
      zellij-shutdown = {
        description = "Kill zellij sessions on shutdown";
        wantedBy = [ "default.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStop = "${pkgs.zellij}/bin/zellij kill-all-sessions --yes";
        };
      };
    };
  };
}
