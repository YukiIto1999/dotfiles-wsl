{
  lib,
  stdenvNoCC,
  makeWrapper,
  dotnetCorePackages,
}:

let
  version = "10.0.750501";
  runtime = dotnetCorePackages.runtime_10_0;
  mkTool =
    pname:
    { description, hash }:
    let
      nupkg = dotnetCorePackages.fetchNupkg { inherit pname version hash; };
    in
    stdenvNoCC.mkDerivation {
      inherit pname version;
      dontUnpack = true;
      nativeBuildInputs = [ makeWrapper ];

      installPhase = ''
        runHook preInstall
        makeWrapper ${lib.getExe runtime} "$out/bin/${pname}" \
          --add-flags "exec ${nupkg}/share/nuget/packages/${pname}/${version}/tools/net8.0/any/${pname}.dll"
        runHook postInstall
      '';

      meta = {
        inherit description;
        homepage = "https://learn.microsoft.com/en-us/dotnet/core/diagnostics/${pname}";
        license = lib.licenses.mit;
        platforms = [ "x86_64-linux" ];
        mainProgram = pname;
        sourceProvenance = [
          lib.sourceTypes.binaryBytecode
        ]
        ++ lib.optional (pname == "dotnet-trace") lib.sourceTypes.binaryNativeCode;
      };
    };
in
lib.mapAttrs mkTool {
  dotnet-counters = {
    description = ".NET performance counter tool";
    hash = "sha256-W045sYK11OI+9FARAQgbat+jyo+TaMvxwIS463y6MJA=";
  };
  dotnet-trace = {
    description = ".NET performance trace tool";
    hash = "sha256-7xfyVySlX5aFv6+FBqd46ofCtieD7KLKcyYyJhKLDU4=";
  };
  dotnet-stack = {
    description = ".NET managed stack reporting tool";
    hash = "sha256-zTXzmf4CPxeTtShZCk1yOh8vHZslaWOG2Saml70kwMo=";
  };
}
