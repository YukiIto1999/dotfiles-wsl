{
  lib,
  pkgs,
  runtime,
}:
{
  hooks = runtime;
  opencodePlugin = pkgs.replaceVars ./package/opencode.ts {
    memoryBinary = lib.getExe runtime;
  };
}
