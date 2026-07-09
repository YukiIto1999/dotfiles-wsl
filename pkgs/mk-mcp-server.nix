{ lib, writeShellScriptBin }:

# 全 stdio MCP server 共通のビルダー
# env の値は export 時に shell 展開される、github-mcp の `$(<file)` はこの展開が前提
{
  name,
  env ? { },
  command,
}:

let
  exports = lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: ''export ${k}="${v}"'') env);
in
writeShellScriptBin name ''
  ${exports}
  exec ${command} "$@"
''
