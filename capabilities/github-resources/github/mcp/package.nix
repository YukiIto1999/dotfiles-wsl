{
  githubMcpServer,
  lib,
  tokenFile,
  toolsets,
  serverBuilder,
  readOnly,
}:

serverBuilder {
  name = "github-mcp";
  requireNonEmpty = [ tokenFile ];
  env.GITHUB_PERSONAL_ACCESS_TOKEN = "$(<${tokenFile})";
  command = lib.escapeShellArgs (
    [
      (lib.getExe githubMcpServer)
      "stdio"
      "--toolsets"
      (lib.concatStringsSep "," toolsets)
    ]
    ++ lib.optional readOnly "--read-only"
  );
}
