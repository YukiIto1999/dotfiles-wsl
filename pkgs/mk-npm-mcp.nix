{
  lib,
  fetchurl,
  buildNpmPackage,
}:

# 複数 MCP server が使う npm 取得の共通 boilerplate
# registryPath はスコープ込みの npm 名、tarball 名は末尾セグメントのみ使う
{
  pname,
  version,
  registryPath ? pname,
  hash,
  lockFile,
  npmDepsHash,
  npmFlags ? [ "--ignore-scripts" ],
  npmInstallFlags ? [ ],
  makeCacheWritable ? false,
  extraPostPatch ? "",
}:

let
  tarballName = lib.last (lib.splitString "/" registryPath);
in
buildNpmPackage (
  {
    inherit
      pname
      version
      npmDepsHash
      npmFlags
      ;
    src = fetchurl {
      url = "https://registry.npmjs.org/${registryPath}/-/${tarballName}-${version}.tgz";
      inherit hash;
    };
    sourceRoot = "package";
    postPatch = ''
      cp ${lockFile} ./package-lock.json
    ''
    + extraPostPatch;
    dontNpmBuild = true;
  }
  // lib.optionalAttrs (npmInstallFlags != [ ]) { inherit npmInstallFlags; }
  // lib.optionalAttrs makeCacheWritable { inherit makeCacheWritable; }
)
