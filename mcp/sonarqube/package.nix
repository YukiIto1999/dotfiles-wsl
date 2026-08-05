{
  mkNpmMcp,
  sonarqubeUrl,
  username,
  passwordFile,
  serverBuilder,
}:

# 自己 host の SonarQube への stdio front。資格情報は起動時に sops file から読む
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
  # env の値は export 時に展開される。password を store へ焼かない
  env.SONARQUBE_PASSWORD = "$(<${passwordFile})";
  requireNonEmpty = [ passwordFile ];
  command = "${pkg}/bin/sonarqube-mcp-server";
}
