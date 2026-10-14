{
  githubMcpServer,
  lib,
  tokenFile,
  toolsets,
  serverBuilder,
}:

serverBuilder {
  name = "github-mcp";
  requireNonEmpty = [ tokenFile ];
  env.GITHUB_PERSONAL_ACCESS_TOKEN = "$(<${tokenFile})";
  command = "${lib.getExe githubMcpServer} stdio --toolsets ${lib.concatStringsSep "," toolsets}";
}
