# NixOS module: splice the zellij zsh-autoattach snippet into
# programs.zsh.interactiveShellInit. Separate from `nixosModules.zellij`
# so a host can pick zellij+config without forcing every interactive zsh
# session to attach.
{
  config,
  lib,
  pkgs,
  ...
}@args:

let
  cfg = config.services.zellij;
  nix-env-lib =
    args.nix-env-lib or (import ../lib {
      nixpkgs = pkgs.path or <nixpkgs>;
      inherit (pkgs) system;
      repoRoot = ../.;
    });
in
{
  options.services.zellij.zshAutoattach = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      On interactive zsh sessions over SSH/mosh, write
      /tmp/zellij-conntype and call `zellij attach -c`. The conntype
      file lets the topbar render the right pill on re-attach (zellij
      caches env at session-creation time and never refreshes it).
    '';
  };

  config = lib.mkIf (cfg.enable && cfg.zshAutoattach) {
    programs.zsh.interactiveShellInit = nix-env-lib.zellij.zshAutoattachSnippet;
  };
}
