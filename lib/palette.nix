# Catppuccin Mocha palette + role aliases. Single source of truth — every
# other config in this repo references these via `lib.${system}.palette`,
# never inlines a literal hex.
#
# Two layers:
#
#   - **Catppuccin names** (`text`, `pink`, `green`, …): the underlying
#     12-shade neutral + 11-shade accent vocabulary. Files that need
#     fine-grained differentiation (eza/theme.yml, the zellij theme)
#     reference these directly.
#
#   - **Role aliases** (`primary`, `accent`, `success`, …): a thin
#     semantic layer on top. Configs that have one obvious role per slot
#     (omp prompt path, claude statusline, zsh syntax, zjstatus topbar)
#     reference these instead of raw Catppuccin names. Re-tinting the
#     project — say, swapping `accent` from green to peach — touches one
#     line here.
#
# `flamingo` and `rosewater` are upstream Catppuccin colors with no role
# assignment in this repo and no current use; included for completeness
# so consumers that override into them have a stable name to target.
#
# `mkPalette` is the override hook: consumers pass `paletteOverride =
# { accent = "#FF0099"; }` (or any other key, including raw Catppuccin
# names) and the override merges over the defaults below. Roles
# resolve *after* the merge, so overriding a base name (e.g. `green`)
# also re-tints every role that points at it (`accent`).
# `variant` selects the Catppuccin flavour: "mocha" (dark, default) or
# "latte" (light). The neutrals run opposite directions between the two
# (`text` is lightest in Mocha, darkest in Latte; `base` vice-versa), so
# the role aliases below produce a coherent light *or* dark theme from the
# same role definitions — only the values flip.
{
  variant ? "mocha",
  paletteOverride ? { },
}:

let
  flavours = {
    # Catppuccin Mocha (dark).
    mocha = {
      # Neutrals (dark → light).
      crust = "#11111B";
      mantle = "#181825";
      base = "#1E1E2E";
      surface0 = "#313244";
      surface1 = "#45475A";
      surface2 = "#585B70";
      overlay0 = "#6C7086";
      overlay1 = "#7F849C";
      overlay2 = "#9399B2";
      subtext0 = "#A6ADC8";
      subtext1 = "#BAC2DE";
      text = "#CDD6F4";

      # Accents.
      rosewater = "#F5E0DC";
      flamingo = "#F2CDCD";
      pink = "#F5C2E7";
      mauve = "#CBA6F7";
      red = "#F38BA8";
      maroon = "#EBA0AC";
      peach = "#FAB387";
      yellow = "#F9E2AF";
      green = "#A6E3A1";
      teal = "#94E2D5";
      sky = "#89DCEB";
      sapphire = "#74C7EC";
      blue = "#89B4FA";
      lavender = "#B4BEFE";
    };
    # Catppuccin Latte (light). Neutrals reverse: `base` is the lightest
    # backdrop, `text` the darkest foreground.
    latte = {
      # Neutrals (light → dark, mirroring Mocha's ordering by role).
      crust = "#DCE0E8";
      mantle = "#E6E9EF";
      base = "#EFF1F5";
      surface0 = "#CCD0DA";
      surface1 = "#BCC0CC";
      surface2 = "#ACB0BE";
      overlay0 = "#9CA0B0";
      overlay1 = "#8C8FA1";
      overlay2 = "#7C7F93";
      subtext0 = "#6C6F85";
      subtext1 = "#5C5F77";
      text = "#4C4F69";

      # Accents.
      rosewater = "#DC8A78";
      flamingo = "#DD7878";
      pink = "#EA76CB";
      mauve = "#8839EF";
      red = "#D20F39";
      maroon = "#E64553";
      peach = "#FE640B";
      yellow = "#DF8E1D";
      green = "#40A02B";
      teal = "#179299";
      sky = "#04A5E5";
      sapphire = "#209FB5";
      blue = "#1E66F5";
      lavender = "#7287FD";
    };
  };

  catppuccin =
    flavours.${variant}
      or (throw "nix-env/palette: unknown variant '${variant}' (expected \"mocha\" or \"latte\")");

  # User-supplied overrides apply *before* roles resolve, so an override
  # of `green` re-tints `accent` (and any other role pointing at it).
  base = catppuccin // paletteOverride;

  # Role aliases — semantic names mapped onto the (possibly overridden)
  # base palette. Roles can themselves be overridden directly: the
  # second merge below lets `paletteOverride = { accent = "#FF0099"; }`
  # win even when the consumer didn't touch `green`.
  roles = {
    # Foreground hierarchy.
    primary = base.text;
    secondary = base.subtext0;
    muted = base.overlay0;

    # Muted UI chrome (zjstatus topbar text + separators) that must stay
    # legible *on `base`* in either flavour. Latte's overlay/surface shades
    # are light greys that wash out on its light base, so light mode steps
    # one rung darker; Mocha keeps overlay0/surface0 (unchanged dark look).
    status_muted = if variant == "latte" then base.subtext0 else base.overlay0;
    status_separator = if variant == "latte" then base.overlay0 else base.surface0;

    # Background hierarchy (5 shades, dark → light).
    bg = base.base;
    bg_alt = base.mantle;
    bg_dim = base.crust;
    bg_surface = base.surface0;
    bg_selection = base.surface2;

    # Status / state.
    success = base.teal;
    warning = base.yellow;
    error = base.red;
    info = base.blue;

    # Semantic accents.
    accent = base.green;
    branch = base.lavender;
    directory = base.mauve;
    highlight = base.peach;
    clean = base.teal;
  };
in
base // roles // paletteOverride
