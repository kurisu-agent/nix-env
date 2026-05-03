{ pkgs, lib }:

let
  # Build-time conversion: hex codepoints → literal UTF-8 glyphs. Lets
  # consumers refer to glyphs by their nf-* slug (e.g. "nf-fa-refresh")
  # without committing PUA-range bytes to source — those are fragile to
  # paste / edit / copy.
  glyphsNix =
    pkgs.runCommand "nerd-fonts-glyphs.nix"
      {
        data = ../data/nerd-fonts.tsv;
      }
      ''
        ${pkgs.python3}/bin/python3 - "$data" > $out <<'PY'
        import sys
        with open(sys.argv[1]) as f:
            print("{")
            for line in f:
                line = line.rstrip("\n")
                if not line or line.startswith("#"):
                    continue
                name, hex_ = line.split("\t")
                print(f'  "{name}" = "{chr(int(hex_, 16))}";')
            print("}")
        PY
      '';

  glyphs = import glyphsNix;

  glyphFor =
    icon:
    if !lib.hasPrefix "nf-" icon then
      icon
    else
      let
        key = lib.removePrefix "nf-" icon;
      in
      glyphs.${key} or (
        throw "unknown nerd-font glyph: ${icon} (add to data/nerd-fonts.tsv)"
      );
in
{
  inherit glyphs glyphFor;
}
