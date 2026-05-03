# Per-system entry: a single attrset wrapping every helper this flake
# exposes. flake.nix calls this for each supported system and surfaces
# the result as `lib.${system}`.
{
  nixpkgs,
  system,
  repoRoot,
}:

let
  pkgs = nixpkgs.legacyPackages.${system};
  inherit (nixpkgs) lib;
  palette = import ./palette.nix;
  nerd-fonts = import ./nerd-fonts.nix { inherit pkgs lib; };
  zellij = import ./zellij.nix {
    inherit
      pkgs
      lib
      repoRoot
      ;
  };
in
{
  inherit palette zellij nerd-fonts;

  claude = import ./claude.nix {
    inherit pkgs palette lib;
  };

  zsh = import ./zsh.nix {
    inherit pkgs lib zellij;
  };
}
