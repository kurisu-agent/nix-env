# NixOS module: shared CLI tools.
#
#   imports = [ inputs.nix-env.nixosModules.cli-tools ];
#   services.cli-tools.enable = true;
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.cli-tools;
in
{
  options.services.cli-tools = {
    enable = lib.mkEnableOption "shared CLI tools (yazi, glow, gh, lazygit, btop, fastfetch)";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      yazi
      glow
      gh
      lazygit
      btop
      fastfetch
    ];
  };
}
