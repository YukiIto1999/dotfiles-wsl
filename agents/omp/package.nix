{
  lib,
  omp,
  pkgs,
}:

let
  system = pkgs.stdenv.hostPlatform.system;
  upstream = omp.packages.${system}.default;

  # The locked OMP revision omitted one bun.lock entry from its generated
  # nix/bun.nix.  Build that entry with the exact bun2nix/nixpkgs inputs used
  # upstream, then merge it into the offline cache.  Once upstream contains
  # the entry, keep its package untouched.
  hasKdl = lib.any (
    path: lib.hasInfix "bun-pkg--bgotink-kdl-0.4.0" (toString path)
  ) upstream.bunDeps.paths;
  ompPkgs = import omp.inputs.nixpkgs {
    inherit system;
    overlays = [ omp.inputs.bun2nix.overlays.default ];
  };
  missingBunDeps = ompPkgs.bun2nix.fetchBunDeps {
    bunNix = ./assets/bun-missing.nix;
  };
  fixedBunDeps = ompPkgs.symlinkJoin {
    name = "omp-bun-cache-fixed";
    paths = [
      upstream.bunDeps
      missingBunDeps
    ];
  };
in
if hasKdl then
  upstream
else
  upstream.overrideAttrs (_: {
    bunDeps = fixedBunDeps;
  })
