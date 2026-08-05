{ lib, ... }:

{
  config = lib.setAttrByPath [
    "_module"
    "args"
  ] { serveOverProxy = "imported-injection"; };
}
