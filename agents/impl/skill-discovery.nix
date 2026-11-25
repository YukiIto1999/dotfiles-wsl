{ lib }:
let
  linesOf = file: lib.splitString "\n" (builtins.readFile file);
  frontmatterOf =
    source:
    let
      lines = linesOf (source + "/SKILL.md");
      isDelimiter = line: builtins.match "---[ \t\r]*" line != null;
    in
    if lines != [ ] && isDelimiter (builtins.head lines) then
      let
        body = builtins.tail lines;
        closing = lib.lists.findFirstIndex isDelimiter null body;
      in
      if closing == null then [ ] else lib.lists.take closing body
    else
      [ ];
  hasFlag =
    frontmatter: name: values:
    lib.any (
      line:
      builtins.match "(${name}|\"${name}\"|'${name}'):[ \t]*(${values})([ \t]*|[ \t]+#.*)\r?" line != null
    ) frontmatter;
  invocationOf =
    source:
    let
      frontmatter = frontmatterOf source;
    in
    {
      model = !(hasFlag frontmatter "disable-model-invocation" "true|True|TRUE");
      user = !(hasFlag frontmatter "user-invocable" "false|False|FALSE");
    };
in
{
  # 利用者も model も呼ばない helper。consumer が原版 source を直接読む
  referenceOnly =
    source:
    let
      invocation = invocationOf source;
    in
    !invocation.model && !invocation.user;
  # 利用者が明示的に呼ぶ command。model の自動選択の候補にしない
  explicitOnly =
    source:
    let
      invocation = invocationOf source;
    in
    !invocation.model && invocation.user;
  # 原版の agents/openai.yaml が model の自動選択を許すか。file が無ければ null
  openaiImplicitInvocationOf =
    source:
    let
      policy = source + "/agents/openai.yaml";
    in
    if builtins.pathExists policy then
      !lib.any (
        line: builtins.match "[ \t]+allow_implicit_invocation:[ \t]*false[ \t]*\r?" line != null
      ) (linesOf policy)
    else
      null;
}
