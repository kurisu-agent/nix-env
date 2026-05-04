# `nix-env-update`: refresh the nix-env clone + reinstall the toolkit.
#
# Three things move in lockstep when "updating nix-env":
#   1. The nix-env repo itself (git pull on the local clone).
#   2. The flake's `nixpkgs` input (drives every package in the toolkit).
#   3. The user's installed `nix-env-toolkit` profile entry.
#
# Doing any one of these by hand is awkward, so this CLI ties them
# together. Exposed as a flake app (`nix run .#update`) and bundled into
# `nix-env-toolkit` so it's on PATH after the first install.
{ pkgs }:

let
  nix-env-update = pkgs.writeShellApplication {
    name = "nix-env-update";
    runtimeInputs = with pkgs; [
      git
      nix
      coreutils
      gnugrep
    ];
    text = ''
      set -euo pipefail

      # Source of truth for the install. Local clone if present (so
      # local edits + `nix flake update` actually take effect); otherwise
      # the upstream GitHub flake.
      repo="''${NIX_ENV_REPO:-$HOME/Code/nix-env}"
      upstream="github:kurisu-agent/nix-env"

      if [ -d "$repo/.git" ] && [ -f "$repo/flake.nix" ]; then
        echo "── syncing $repo ──"
        git -C "$repo" fetch --all --prune
        if ! git -C "$repo" pull --ff-only; then
          echo "warn: $repo is not fast-forward; leaving as-is" >&2
        fi

        echo ""
        echo "── updating flake inputs ──"
        nix flake update --flake "$repo"
        src="$repo"
      else
        echo "no local clone at $repo; using $upstream"
        src="$upstream"
      fi

      attr="$src#nix-env-toolkit"

      echo ""
      if nix profile list 2>/dev/null | grep -q nix-env-toolkit; then
        echo "── upgrading nix-env-toolkit ──"
        nix profile upgrade --regex nix-env-toolkit
      else
        echo "── installing nix-env-toolkit ──"
        nix profile install "$attr"
      fi

      if [ "$src" = "$repo" ] && ! git -C "$repo" diff --quiet flake.lock 2>/dev/null; then
        echo ""
        echo "note: $repo/flake.lock has uncommitted changes — commit + push when ready."
      fi
    '';
  };
in
{
  inherit nix-env-update;
}
