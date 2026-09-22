{
  lib,
  serverBuilder,
  runtime,
}:
serverBuilder {
  name = "hindsight-mcp";
  command = "${lib.getExe runtime} mcp";
}
