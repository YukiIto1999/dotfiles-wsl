{ lib, ... }:

{
  config = lib.setAttrByPath [
    "_module"
    "args"
  ] { frontBuilder = "imported-injection"; };
}
