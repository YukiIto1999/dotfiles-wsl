{
  lib,
  buildNpmPackage,
}:

{
  pname,
  version,
  src,
  lockFile,
  npmDepsHash,
  npmFlags ? [ "--ignore-scripts" ],
  npmInstallFlags ? [ ],
  makeCacheWritable ? false,
  extraPostPatch ? "",
}:

buildNpmPackage (
  {
    inherit
      pname
      version
      src
      npmDepsHash
      npmFlags
      ;
    postPatch = ''
      cp ${lockFile} ./package-lock.json
    ''
    + extraPostPatch;
    dontNpmBuild = true;
  }
  // lib.optionalAttrs (npmInstallFlags != [ ]) { inherit npmInstallFlags; }
  // lib.optionalAttrs makeCacheWritable { inherit makeCacheWritable; }
)
