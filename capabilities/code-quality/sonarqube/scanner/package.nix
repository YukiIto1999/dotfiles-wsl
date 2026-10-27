{
  lib,
  python3,
  git,
  sonar-scanner-cli,
  commandBuilder,
  serverUrl,
}:

commandBuilder {
  name = "dotfiles-sonarqube-scan";
  src = ./impl/entry.sh;
  runtimeInputs = [ git ];
  vars = {
    python = lib.getExe python3;
    source = "${./impl/scan.py}";
    scanner = lib.getExe sonar-scanner-cli;
    scannerPackageVersion = sonar-scanner-cli.version;
    inherit serverUrl;
  };
}
