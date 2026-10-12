{
  lib,
  fetchurl,
  jre_headless,
  serverBuilder,
  sonarqubeUrl,
  tokenFile,
  storagePath,
}:

let
  version = "1.19.0.2785";
  jar = fetchurl {
    url = "https://binaries.sonarsource.com/Distribution/sonarqube-mcp-server/sonarqube-mcp-server-${version}.jar";
    hash = "sha256-pszNX4PA7Lo42QkZv611Ql3na6gPu390LPqCA1rz0PI=";
  };
in
serverBuilder {
  name = "sonarqube-mcp";
  requireNonEmpty = [ tokenFile ];
  env = {
    SONARQUBE_URL = sonarqubeUrl;
    SONARQUBE_TOKEN = "$(<${tokenFile})";
    STORAGE_PATH = storagePath;
    SONARQUBE_READ_ONLY = "true";
    SONARQUBE_TOOLSETS = "issues,quality-gates,measures,sources,system";
    SONARQUBE_DEBUG_ENABLED = "false";
    SONARQUBE_LOG_TO_FILE_DISABLED = "true";
    TELEMETRY_DISABLED = "true";
  };
  command = "${lib.getExe jre_headless} -Xmx768m -XX:-HeapDumpOnOutOfMemoryError -XX:ErrorFile=/dev/null -jar ${jar}";
}
