{ lib, fetchurl, buildNpmPackage }:

# npm registry の tgz を fetch して buildNpmPackage する共通 boilerplate
# registryPath はスコープ込みの npm 名(例 "@upstash/context7-mcp")、tarball 名は末尾のみ
{ pname
, version
, registryPath ? pname
, hash
, lockFile
, npmDepsHash
, npmFlags ? [ "--ignore-scripts" ]
, npmInstallFlags ? [ ]
, makeCacheWritable ? false
, extraPostPatch ? ""
}:

let
  tarballName = lib.last (lib.splitString "/" registryPath);
in
buildNpmPackage ({
  inherit pname version npmDepsHash npmFlags;
  src = fetchurl {
    url = "https://registry.npmjs.org/${registryPath}/-/${tarballName}-${version}.tgz";
    inherit hash;
  };
  sourceRoot = "package";
  postPatch = ''
    cp ${lockFile} ./package-lock.json
  '' + extraPostPatch;
  dontNpmBuild = true;
}
// lib.optionalAttrs (npmInstallFlags != [ ]) { inherit npmInstallFlags; }
// lib.optionalAttrs makeCacheWritable { inherit makeCacheWritable; })
