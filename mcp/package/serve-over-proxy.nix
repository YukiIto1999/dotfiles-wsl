{ lib, pkgs }:
command: port:
"${lib.getExe pkgs.mcp-proxy} --host 127.0.0.1 --port ${toString port} --stateless -- ${command}"
