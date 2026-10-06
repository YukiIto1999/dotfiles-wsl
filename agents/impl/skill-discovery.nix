{ lib }:
source:
let
  lines = lib.splitString "\n" (builtins.readFile (source + "/SKILL.md"));
  isDelimiter = line: builtins.match "---[ \t\r]*" line != null;
  frontmatter =
    if lines != [ ] && isDelimiter (builtins.head lines) then
      let
        body = builtins.tail lines;
        closing = lib.lists.findFirstIndex isDelimiter null body;
      in
      if closing == null then [ ] else lib.lists.take closing body
    else
      [ ];
  hasFlag =
    name: values:
    lib.any (
      line:
      builtins.match "(${name}|\"${name}\"|'${name}'):[ \t]*(${values})([ \t]*|[ \t]+#.*)\r?" line != null
    ) frontmatter;
in
hasFlag "user-invocable" "false|False|FALSE" && hasFlag "disable-model-invocation" "true|True|TRUE"
