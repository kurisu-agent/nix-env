# Per-system entry: a single attrset wrapping every helper this flake
# exposes. flake.nix calls this for each supported system and surfaces
# the result as `lib.${system}`.
#
# `paletteOverride` is the top-level override knob. Consumers that
# import this lib (either via flake.nix's `mkLib` or the standalone
# fallback paths in nixos/*.nix) can pass `paletteOverride = { accent =
# "#FF0099"; }` to retint the whole project. Roles resolve after the
# override merge, so overriding a Catppuccin base name (e.g. `green`)
# also retints every role that points at it (`accent`, `clean`).
{
  nixpkgs,
  system,
  repoRoot,
  paletteOverride ? { },
}:

let
  pkgs = nixpkgs.legacyPackages.${system};
  inherit (nixpkgs) lib;

  palette = import ./palette.nix { inherit paletteOverride; };

  # Hex → RGB conversion. Used by claude.nix for ANSI 38;2;R;G;B truecolor
  # escapes and by zellij theme rendering for `R G B` KDL values.
  hexDigit =
    let
      table = {
        "0" = 0; "1" = 1; "2" = 2; "3" = 3; "4" = 4;
        "5" = 5; "6" = 6; "7" = 7; "8" = 8; "9" = 9;
        "a" = 10; "A" = 10; "b" = 11; "B" = 11;
        "c" = 12; "C" = 12; "d" = 13; "D" = 13;
        "e" = 14; "E" = 14; "f" = 15; "F" = 15;
      };
    in
    c: table.${c};

  hexByte = s: 16 * (hexDigit (builtins.substring 0 1 s)) + (hexDigit (builtins.substring 1 1 s));

  stripHash =
    s:
    if builtins.substring 0 1 s == "#" then builtins.substring 1 (builtins.stringLength s - 1) s else s;

  hexToRgb =
    hex:
    let
      h = stripHash hex;
    in
    {
      r = hexByte (builtins.substring 0 2 h);
      g = hexByte (builtins.substring 2 2 h);
      b = hexByte (builtins.substring 4 2 h);
    };

  hexToRgbCsv =
    hex:
    let
      rgb = hexToRgb hex;
    in
    "${toString rgb.r};${toString rgb.g};${toString rgb.b}";

  hexToRgbSpaceSep =
    hex:
    let
      rgb = hexToRgb hex;
    in
    "${toString rgb.r} ${toString rgb.g} ${toString rgb.b}";

  colorHelpers = {
    inherit
      hexToRgb
      hexToRgbCsv
      hexToRgbSpaceSep
      ;
  };

  # Build the placeholder → value substitution pairs from the palette.
  # Each color contributes three entries: hex, space-separated RGB, and
  # semicolon-separated RGB. The latter two cover the formats KDL and
  # ANSI/zjstatus need without forcing each template to pre-convert.
  paletteSubs = lib.concatLists (
    lib.mapAttrsToList (name: hex: [
      { from = "@pal_${name}@"; to = hex; }
      { from = "@pal_${name}_rgb@"; to = hexToRgbSpaceSep hex; }
      { from = "@pal_${name}_rgb_csv@"; to = hexToRgbCsv hex; }
    ]) palette
  );

  substitutePalette =
    text:
    builtins.replaceStrings (map (s: s.from) paletteSubs) (map (s: s.to) paletteSubs) text;

  # Sed-args form for runCommand-based substitution (used inside zellij
  # layouts, where __ZJSTATUS__ / __STATUS_CMD__ / __TIMEZONE__ are also
  # resolved by sed in the same pass).
  paletteSedArgs = lib.concatStringsSep " " (
    map (s: "-e 's|${s.from}|${s.to}|g'") paletteSubs
  );

  # Pre-rendered static asset files. Used by flake.nix outputs and the
  # NixOS modules so the same artifact is shipped in every code path.
  ompTheme = pkgs.writeText "nix-env-omp-theme.json" (
    substitutePalette (builtins.readFile (repoRoot + "/omp/theme.json"))
  );

  ezaTheme = pkgs.writeText "nix-env-eza-theme.yml" (
    substitutePalette (builtins.readFile (repoRoot + "/eza/theme.yml"))
  );

  paletteHelpers = {
    inherit
      paletteSubs
      substitutePalette
      paletteSedArgs
      ;
  };

  nerd-fonts = import ./nerd-fonts.nix { inherit pkgs lib; };

  zellij = import ./zellij.nix {
    inherit
      pkgs
      lib
      repoRoot
      palette
      paletteHelpers
      ;
  };
in
{
  inherit
    palette
    zellij
    nerd-fonts
    ompTheme
    ezaTheme
    ;
  inherit (colorHelpers) hexToRgb hexToRgbCsv hexToRgbSpaceSep;
  inherit (paletteHelpers) substitutePalette paletteSedArgs paletteSubs;

  # In-place override hook. Returns a fresh palette attrset with the
  # given override merged on top of (paletteOverride // defaults).
  # Consumers building one-off derivations don't need to re-import the
  # whole lib just to retint a single color.
  mkPalette = override: import ./palette.nix { paletteOverride = paletteOverride // override; };

  claude = import ./claude.nix {
    inherit
      pkgs
      lib
      palette
      colorHelpers
      ;
  };

  zsh = import ./zsh.nix {
    inherit
      pkgs
      lib
      zellij
      palette
      ;
  };
}
