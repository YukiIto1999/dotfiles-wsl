{ lib, writeShellScriptBin }:

# 全 stdio MCP server 共通のビルダー、env を export し command を exec
{ name, env ? { }, command }:

let
  exports = lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: ''export ${k}="${v}"'') env);
in
writeShellScriptBin name ''
  ${exports}
  exec ${command} "$@"
''
