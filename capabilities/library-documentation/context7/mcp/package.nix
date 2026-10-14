{
  context7Mcp,
  lib,
  serverBuilder,
}:

serverBuilder {
  name = "context7-mcp";
  command = lib.getExe context7Mcp;
}
