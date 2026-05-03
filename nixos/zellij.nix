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
  nix-env-pkgs ? pkgs,
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

  # Drop null fields so identity.json is `{}` rather than `{"color":null,...}`.
  # status.sh's `jq -r '.X // empty'` handles either, but the shorter form is
  # nicer to read when debugging a host's rendered file. Resolve nf-* icon
  # slugs to literal glyphs at write-time (lib/nerd-fonts.nix).
  identityAttrs = lib.optionalAttrs (cfg.identity != null) (
    lib.filterAttrs (_: v: v != null) (
      cfg.identity
      // lib.optionalAttrs (cfg.identity.icon or null != null) {
        icon = nix-env-lib.nerd-fonts.glyphFor cfg.identity.icon;
      }
    )
  );

  identityJson = pkgs.writeText "nix-env-zellij-identity.json" (builtins.toJSON identityAttrs);

  paletteNames = [
    "text"
    "subtext0"
    "overlay0"
    "pink"
    "mauve"
    "lavender"
    "blue"
    "sapphire"
    "sky"
    "teal"
    "green"
    "yellow"
    "peach"
    "red"
  ];
in
{
  options.services.zellij = {
    enable = lib.mkEnableOption "Zellij terminal multiplexer with the nix-env shared config";

    package = lib.mkOption {
      type = lib.types.package;
      default = nix-env-pkgs.zellij;
      defaultText = lib.literalExpression "nix-env-pkgs.zellij";
      description = "Zellij package. Defaults to nix-env's pinned version so the zellij ABI matches zjstatus.wasm.";
    };

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
      default = "/tmp/zellij-1000";
      example = "/tmp/zellij-1000";
      description = ''
        `ZELLIJ_SOCKET_DIR` system-wide override. Defaults to
        `/tmp/zellij-1000` to fix the mosh/SSH split-brain — mosh-server
        doesn't inherit `XDG_RUNTIME_DIR` from PAM, so zellij falls back
        to `/tmp/zellij-$UID` while SSH sessions (which do inherit it)
        find sockets at `/run/user/$UID/zellij`. Two access paths, two
        socket dirs, can't see each other's sessions. Pinning the path
        forces both to converge.

        Set to `null` on multi-user systems (the literal string can't
        expand `$UID`, so every user would collide on `/tmp/zellij-1000`)
        or hosts running zellij under a UID other than 1000.
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

    identity = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            color = lib.mkOption {
              type = lib.types.nullOr (lib.types.enum paletteNames);
              default = null;
              description = ''
                Catppuccin palette name used to tint the topbar identity
                segment (and the optional `user` character on the right).
                Unknown / null values render as overlay0 (grey).
              '';
            };
            name = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''
                Display name on the left of the topbar. Falls back to
                `hostname -s` when null.
              '';
            };
            icon = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''
                Single grapheme rendered before `name` (emoji or
                nerd-font glyph). No icon when null.
              '';
            };
            user = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''
                Optional character/user string rendered on the right of
                the topbar in the same color as `color`. Hidden when null.
              '';
            };
          };
        }
      );
      default = null;
      example = {
        color = "peach";
        name = "dev";
        icon = "🛠";
      };
      description = ''
        Topbar identity declared from Nix. When set, materialises
        `~/.config/zellij/identity.json` on user activation, which
        `nix-env-zellij-status` reads each poll. All sub-fields are
        optional; missing fields fall back to the defaults baked into
        `status.sh` (hostname for name, no icon, overlay0 colour, no
        user character).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

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

    system.userActivationScripts.nixEnvZellijIdentity = lib.mkIf (cfg.identity != null) {
      text = ''
        mkdir -p "$HOME/.config/zellij"
        install -m 0644 ${identityJson} "$HOME/.config/zellij/identity.json"
      '';
    };

    systemd.user.services = lib.mkIf cfg.killOnShutdown {
      zellij-shutdown = {
        description = "Kill zellij sessions on shutdown";
        wantedBy = [ "default.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStop = "${cfg.package}/bin/zellij kill-all-sessions --yes";
        };
      };
    };
  };
}
