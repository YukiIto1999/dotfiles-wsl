{ pkgs, ... }: {
  source = [
    {
      sonarqube-scan-evidence =
        pkgs.runCommandLocal "check-sonarqube-scan-evidence"
          {
            nativeBuildInputs = [
              pkgs.git
              pkgs.python3
            ];
          }
          ''
            ${pkgs.python3}/bin/python ${./checks/evidence.py} ${./impl/scan.py}
            touch "$out"
          '';
    }
  ];
}
