{
  lib,
  writeShellApplication,
  zvecGrep,
  port,
}:

writeShellApplication {
  name = "zvec-grep-mcp";
  text = ''
    exec ${lib.getExe zvecGrep} server run --listen 127.0.0.1:${toString port} --mcp-toolset agent
  '';
}
