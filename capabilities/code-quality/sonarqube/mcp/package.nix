{
  mkNpmMcp,
  sonarqubeUrl,
  username,
  passwordFile,
  serverBuilder,
}:

let
  pkg = mkNpmMcp {
    pname = "sonarqube-mcp-server";
    version = "1.10.21";
    hash = "sha256-bJXCkWBmvP08lG/9X96dRIGkp+sO4bvu79aldutiT0o=";
    lockFile = ./package/package-lock.json;
    npmDepsHash = "sha256-sBW2ckDRuwXTiDsG6vhT3DjWtekhzmtupJ/m8niSlb4=";
  };
in
serverBuilder {
  name = "sonarqube-mcp";
  env.SONARQUBE_URL = sonarqubeUrl;
  env.SONARQUBE_USERNAME = username;
  # 評価時展開では Nix store に混入する SonarQube password
  env.SONARQUBE_PASSWORD = "$(<${passwordFile})";
  requireNonEmpty = [ passwordFile ];
  command = "${pkg}/bin/sonarqube-mcp-server";
}
