{ lib, writeShellScriptBin }:

{
  name,
  env ? { },
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
