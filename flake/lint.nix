# Lint and format apps for the flake.
#
# Single source of truth for `nix run .#lint` (read-only check, used by
# git pre-commit + Claude Code hooks + CI) and `nix run .#fmt` (auto-fix
# variant invoked by hand). Add new tools here, not in hook configs.
{ pkgs }:

let
  tools = [
    pkgs.nixfmt # RFC-style; nixfmt-rfc-style is now an alias.
    pkgs.statix
    pkgs.deadnix
    pkgs.git
  ];

  # Read-only: each step exits non-zero on findings. Safe for hooks.
  lint = pkgs.writeShellApplication {
    name = "nix-lint";
    runtimeInputs = tools;
    text = ''
      set -eu
      cd "$(git rev-parse --show-toplevel)"
      mapfile -t files < <(git ls-files '*.nix')
      if [ ''${#files[@]} -eq 0 ]; then
        echo "no .nix files tracked"
        exit 0
      fi
      echo "→ nixfmt --check (''${#files[@]} files)"
      nixfmt --check "''${files[@]}"
      echo "→ statix check"
      statix check .
      echo "→ deadnix --fail"
      deadnix --fail "''${files[@]}"
    '';
  };

  # Auto-fix: mutates files. Run deliberately, not from hooks.
  fmt = pkgs.writeShellApplication {
    name = "nix-fmt";
    runtimeInputs = tools;
    text = ''
      set -eu
      cd "$(git rev-parse --show-toplevel)"
      mapfile -t files < <(git ls-files '*.nix')
      if [ ''${#files[@]} -eq 0 ]; then exit 0; fi
      echo "→ nixfmt (''${#files[@]} files)"
      nixfmt "''${files[@]}"
      echo "→ statix fix"
      statix fix .
      echo "→ deadnix --edit"
      deadnix --edit "''${files[@]}"
    '';
  };
in
{
  inherit lint fmt;
}
