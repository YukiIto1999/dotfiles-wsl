{ lib, writeShellScriptBin }:

# 全 stdio MCP server 共通のビルダー、env を export し command を exec
# env の値は export 時に shell 展開される(github-mcp の `$(<file)` が前提とする契約)
{ name, env ? { }, command }:

let
  exports = lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: ''export ${k}="${v}"'') env);
in
writeShellScriptBin name ''
  ${exports}
  exec ${command} "$@"
''
