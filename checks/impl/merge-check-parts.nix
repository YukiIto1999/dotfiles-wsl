{ lib }:

parts:
let
  names = lib.concatMap builtins.attrNames parts;
  duplicateNames = lib.unique (
    builtins.filter (name: lib.count (candidate: candidate == name) names > 1) names
  );
in
if duplicateNames == [ ] then
  lib.foldl' (checks: part: checks // part) { } parts
else
  throw "duplicate check part id: ${lib.concatStringsSep " " duplicateNames}"
