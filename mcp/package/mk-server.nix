{ lib, writeShellScriptBin }:

# 全 stdio MCP server 共通のビルダー
# env の値は export 時に shell 展開される、github-mcp の `$(<file)` はこの展開が前提
{
  name,
  env ? { },
  # 起動前に満たすべき条件。空なら検査しない。command と混ぜると exec の位置が
  # 壊れるので、guard は独立した行として置く
  requireNonEmpty ? [ ],
  command,
}:

let
  exports = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      k: v:
      if lib.hasInfix "$(" v then
        ''
          ${k}="${v}"
          export ${k}
        ''
      else
        ''export ${k}="${v}"''
    ) env
  );

  guards = lib.concatMapStringsSep "\n" (path: ''
    if [ ! -s ${path} ]; then
      echo "${name}: required file is empty: ${path}" >&2
      exit 1
    fi
  '') requireNonEmpty;
in
writeShellScriptBin name ''
  ${exports}
  ${guards}
  exec ${command} "$@"
''
