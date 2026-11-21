{
  lib,
  writeShellScriptBin,
  dotnetCorePackages,
}:

let
  pname = "microsoft.aitools.binlogmcp";
  version = "3.0.5";
  source = dotnetCorePackages.fetchNupkg {
    inherit pname version;
    hash = "sha256-7mxKsIatvtXP2RiHLNAnIal7u/kNb8U6SmSmnOcyGuE=";
  };
  assembly = "${source}/share/nuget/packages/${pname}/${version}/tools/net10.0/any/Microsoft.AITools.BinlogMcp.dll";
in
writeShellScriptBin "binlog-mcp" ''
  # .NET Generic Host が作業ディレクトリ全体を監視するため、systemd の既定値 / で起動しない
  cd -- "''${RUNTIME_DIRECTORY:?systemd runtime directory is not set}" || exit 1
  export DOTNET_CLI_TELEMETRY_OPTOUT=1
  exec ${lib.getExe dotnetCorePackages.runtime_10_0} exec ${assembly} "$@"
''
