{ lib, ... }:

{
  config = lib.setAttrByPath [
    "_module"
    "args"
  ] { mkNpmMcp = "direct-injection"; };
}
