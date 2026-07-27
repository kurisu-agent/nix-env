# NixOS module: shared CLI tools, plus the btop interactive SETTINGS.
#
# The package list used to be the whole module, which meant every consumer
# got btop with upstream's defaults: 2000 ms refresh (graphs look frozen,
# the CPU/net meters lag reality by two seconds — over ssh it reads as a
# hung TUI), an opaque self-painted background over Ghostty's Catppuccin
# blur, and the washed-out built-in Default theme because no
# `catppuccin.theme` file was ever placed. The *values* that fix all three
# lived in exactly one COSMIC workstation's home-manager, split from the
# theme file they are a matched pair with, so no drift kart and no
# circuit/update VM ever saw them. They live here now.
#
#   imports = [ inputs.nix-env.nixosModules.cli-tools ];
#   services.cli-tools.enable = true;
{
  config,
  lib,
  pkgs,
  ...
}@args:

let
  cfg = config.services.cli-tools;

  # Same standalone-fallback shape as nixos/zsh.nix: prefer the lib
  # flake.nix's `mkModule` injects, fall back to importing ./lib so this
  # module still evaluates under a bare `nixos-rebuild build-vm`.
  baseLib =
    args.nix-env-lib or (import ../lib {
      nixpkgs = pkgs.path or <nixpkgs>;
      inherit (pkgs) system;
      repoRoot = ../.;
    });

  # "follow": bake NO flavour and pass NO `--themes-dir`. btop searches its
  # custom theme dir BEFORE `$HOME/.config/btop/themes`
  # (btop_theme.cpp#loadThemes), so a baked dir would SHADOW the runtime
  # symlink a follow-mode consumer's theme watcher repoints per light/dark —
  # the toggle would just stop working, with nothing in the config to grep
  # for. Mirrors `services.zsh.variant = "follow"`.
  follow = cfg.variant == "follow";

  # Read by `btopThemesDir` and nothing else, so in follow mode — which renders
  # no themes dir — the whole binding is dead and `reconfigure` (which takes
  # only mocha|latte) must not be called. That makes `paletteOverride` INERT
  # under follow; the option's description says so.
  nix-env-lib =
    if follow || (cfg.variant == "mocha" && cfg.paletteOverride == { }) then
      baseLib
    else
      baseLib.reconfigure { inherit (cfg) variant paletteOverride; };

  # btop.conf is flat `key = value`. Bools render True/False, ints bare,
  # strings DOUBLE-QUOTED (btop's loader reads to the closing quote when it
  # sees one, else to the next whitespace).
  #
  # A `"` or `\` inside a string value is ESCAPED rather than emitted raw: btop
  # reads a quoted value up to the closing quote, so a bare `"` would truncate
  # the value and leave the remainder as a stray token — which trips the load
  # warning that flips `write_new` on, and then btop tries (and silently fails)
  # to rewrite the read-only store path. None of the defaults below can hit
  # this; a consumer setting something like `custom_cpu_name` can.
  btopValue =
    v:
    if lib.isBool v then
      (if v then "True" else "False")
    else if lib.isInt v then
      toString v
    else
      "\"${lib.escape [ "\\" "\"" ] v}\"";

  # The `#?` header is not decoration. btop's #load sets `write_new` unless
  # line 1 starts with `#` AND contains btop's own version string, and #write
  # then rewrites the whole file on exit — a write to a read-only store path
  # guarded by a bare `if (cwrite.good())`, so it fails silently (upstream
  # even has a `// TODO: Report error` there). Emitting the header keeps
  # `write_new` false so btop never attempts it.
  #
  # `null` values are dropped: that is how a consumer UNSETS one of the
  # defaults below without restating the whole attrset.
  btopConf = pkgs.writeText "nix-env-btop.conf" (
    "#? Config file for btop v.${cfg.btop.package.version}\n\n"
    + lib.concatStringsSep "\n" (
      lib.mapAttrsToList (k: v: "${k} = ${btopValue v}") (
        lib.filterAttrs (_: v: v != null) cfg.btop.settings
      )
    )
    + "\n"
  );

  # Named catppuccin.theme because `color_theme` matches by file STEM, so the
  # same setting string resolves to Mocha or Latte purely by which file is on
  # the search path. An absolute store path in `color_theme` does NOT work:
  # btop populates its theme list only from the dirs it searches, so a path
  # outside them is never matched and it falls back to Default.
  btopThemesDir = pkgs.runCommand "nix-env-btop-themes" { } ''
    mkdir -p $out
    cp ${nix-env-lib.btopTheme} $out/catppuccin.theme
  '';

  # WHY A WRAPPER AND NOT /etc/xdg/btop LIKE eza GETS.
  # btop's get_config_dir() reads `$XDG_CONFIG_HOME/btop` or
  # `$HOME/.config/btop` and NOTHING ELSE — no XDG_CONFIG_DIRS, no
  # BTOP_CONFIG env var. An `environment.etc."xdg/btop/btop.conf"` drop is a
  # SILENT no-op, so the `/etc/xdg/eza` trick from nixos/zsh.nix does not
  # transfer. `-c/--config` plus `--themes-dir` is the entire API, which
  # makes wrapping the only placement that needs no write to $HOME — and
  # needing no write to $HOME is the requirement: a drift kart's /home/dev is
  # a fresh overlay every boot with no home-manager, and
  # `system.userActivationScripts` cannot help there (it is a systemd --user
  # unit, and the kart's sshd runs UsePAM=false so no user manager ever
  # starts — the same reason the ~/.zshrc wizard had to be fixed with
  # tmpfiles instead).
  #
  # `--config` moves the config FILE, not `conf_dir`, so
  # `$HOME/.config/btop/themes` stays on the theme search path in EVERY
  # mode. That one fact is what lets one mechanism serve a follow-mode
  # workstation and a fixed-flavour kart.
  #
  # Flags land before "$@" and btop's `-c` parser is last-wins with no
  # set-twice guard, so an operator's `btop -c ~/mine.conf` still overrides
  # everything here.
  btopWrapped = pkgs.symlinkJoin {
    name = "btop-nix-env-${cfg.btop.package.version}";
    paths = [ cfg.btop.package ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/btop \
        --add-flags "--config ${btopConf}" \
        ${lib.optionalString (!follow) ''--add-flags "--themes-dir ${btopThemesDir}"''}
    '';
  };
in
{
  options.services.cli-tools = {
    enable = lib.mkEnableOption "shared CLI tools (yazi, glow, gh, lazygit, btop, fastfetch) with the nix-env interactive settings";

    variant = lib.mkOption {
      type = lib.types.enum [
        "mocha"
        "latte"
        "follow"
      ];
      default = "mocha";
      description = ''
        Catppuccin flavour for the btop theme FILE. "mocha" / "latte" bake a
        themes dir and hand btop `--themes-dir`, so the theme works with
        nothing written to `$HOME` — what a drift kart needs, since its
        /home/dev is a fresh overlay with no user session to run an
        activation script. "follow" bakes nothing and passes no
        `--themes-dir`, leaving `~/.config/btop/themes/catppuccin.theme`
        (which btop searches in every mode) to the consumer's theme watcher,
        so light/dark switching keeps working live.

        No SETTING is flavour-dependent: `color_theme` names a theme file by
        stem, so it resolves to whichever flavour is on the search path. This
        knob selects the FILE only.
      '';
    };

    paletteOverride = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        accent = "#FF0099";
      };
      description = ''
        Partial-merge palette override applied to lib/palette.nix before the
        btop theme is rendered. See `services.zellij.paletteOverride` for
        naming details.

        IGNORED when `variant = "follow"`: follow mode renders no theme file
        at all (it hands btop no `--themes-dir`, so the flavour comes from
        whatever the consumer's theme watcher links into
        `~/.config/btop/themes`). Override the palette on the SOURCE of that
        link instead. No setting is palette-dependent, so nothing else here
        is affected.
      '';
    };

    btop = {
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.btop;
        defaultText = lib.literalExpression "pkgs.btop";
        description = ''
          btop package, shipped wrapped with the rendered config (and,
          outside follow mode, the baked themes dir). Its `version` is also
          what goes in the config file's `#?` header, which is what stops
          btop rewriting the file — so a package whose version string
          disagrees with the binary would reintroduce that.
        '';
      };

      wrap = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Ship btop wrapped with `--config` (and `--themes-dir` outside
          follow mode). This is the only way to give btop a system-owned
          config: it reads no system-wide path and honours no config env var.

          The cost: btop cannot persist a change made in its own options
          menu — it rewrites the whole file and the store path is read-only,
          so the write is silently dropped. That was already true of any
          home-manager-managed btop, so this regresses nothing. Set false to
          ship the bare package and let btop own `~/.config/btop` itself.
        '';
      };

      settings = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.nullOr (
            lib.types.oneOf [
              lib.types.bool
              lib.types.int
              lib.types.str
            ]
          )
        );
        default = { };
        example = {
          update_ms = 100;
          proc_tree = true;
        };
        description = ''
          btop.conf keys. Typed bool/int/str because that is exactly what
          btop's parser accepts, so a wrong-shaped value fails at eval
          instead of landing as a runtime load warning (which flips btop's
          `write_new` on and makes it try to rewrite the store path).

          `null` OMITS a key — that is how you unset one of this module's
          defaults without restating the others.

          The DEFAULTS are mkDefault-ed definitions in this module's own
          `config` block, NOT this option's `default`. See the comment there
          for why that distinction is load-bearing.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # THE VALUES — single source of truth, moved out of nix-config's COSMIC
    # home-manager where they were reachable by exactly ONE consumer and
    # split from the theme FILE they are a matched pair with.
    #
    # Declared as ordinary DEFINITIONS carrying lib.mkDefault, deliberately
    # NOT as the option's `default`. NixOS discards an option's default the
    # moment ANY definition exists, so with `default = { update_ms = 200;
    # ... }` a consumer writing `settings.update_ms = 100` would SILENTLY
    # LOSE theme_background and color_theme — a config that still evaluates,
    # and still reads correctly in this file, while btop comes up opaque and
    # unthemed. As mkDefault-ed definitions, types.attrsOf splits the merge
    # per attribute NAME and discharges the priority per LEAF: the consumer's
    # plain definition (100) beats mkDefault (1000) on that one key and
    # inherits the rest. Two consumers setting the SAME key differently is an
    # eval error, which is right — it forces an explicit lib.mkForce rather
    # than letting import order decide silently.
    services.cli-tools.btop.settings = {
      # btop's own default is 2000 ms. Every graph looks frozen and the
      # CPU/net meters lag reality by two seconds; over ssh it reads as a
      # hung TUI. 200 ms is what the workstation has always run.
      update_ms = lib.mkDefault 200;
      # btop's own default is True: it paints its theme's main_bg as an
      # opaque fill, so Ghostty's Catppuccin background and blur disappear
      # behind a flat rectangle. This is the MATCHED HALF of
      # btop/theme.theme's own header note ("main_bg is only painted when
      # theme_background=true; our hosts set theme_background=false so btop
      # borrows the terminal background") — the setting and the theme file
      # are one artifact, which is why they now live in one repo instead of
      # two.
      theme_background = lib.mkDefault false;
      # Names a theme FILE BY STEM, so this one string resolves to Mocha or
      # Latte depending on which catppuccin.theme is on the search path —
      # flavour-agnostic on purpose, with `variant` selecting the file. Do
      # NOT put an absolute store path here: btop populates its theme list
      # only from the dirs it searches, so a path outside them never matches
      # and it silently falls back to its washed-out built-in Default.
      color_theme = lib.mkDefault "catppuccin";
    };

    environment.systemPackages =
      (with pkgs; [
        yazi
        glow
        gh
        lazygit
        fastfetch
      ])
      ++ [ (if cfg.btop.wrap then btopWrapped else cfg.btop.package) ];
  };
}
