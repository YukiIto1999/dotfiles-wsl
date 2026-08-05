let
  entries = {
    "/fixture" = {
      zeta = "directory";
      "package-only" = "directory";
      "symlink-marker" = "directory";
      "checks-only" = "directory";
      alpha = "directory";
      "impl-only" = "directory";
    };
    "/fixture/zeta" = {
      "module.nix" = "regular";
    };
    "/fixture/package-only" = {
      "package.nix" = "regular";
    };
    "/fixture/symlink-marker" = {
      "module.nix" = "symlink";
    };
    "/fixture/impl-only" = {
      impl = "directory";
    };
    "/fixture/impl-only/impl" = { };
    "/fixture/checks-only" = {
      "checks.nix" = "regular";
    };
    "/fixture/alpha" = {
      nested = "directory";
      "module.nix" = "regular";
    };
    "/fixture/alpha/nested" = {
      "module.nix" = "regular";
    };
  };
in
{
  root = "/fixture";
  expectedIds = [
    "alpha"
    "alpha/nested"
    "zeta"
  ];
  readDir = path: entries.${toString path};
}
