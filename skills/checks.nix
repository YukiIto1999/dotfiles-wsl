{
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  registry = hostConfig.dotfiles.skills.registry;
  manifest = pkgs.writeText "skill-frontmatter-manifest.json" (
    builtins.toJSON (lib.mapAttrs (_: skill: "${skill.source}") registry)
  );
  validator = pkgs.writeText "skill-frontmatter-contract.py" ''
    import json
    import re
    import sys

    KEY = re.compile(r"^([A-Za-z0-9_-]+):(.*)$")

    def frontmatter(lines):
        if not lines or lines[0] != "---" or "---" not in lines[1:]:
            return None
        body = lines[1 : lines[1:].index("---") + 1]
        fields = {}
        key = None
        for line in body:
            matched = KEY.match(line)
            if matched:
                key = matched.group(1)
                fields[key] = matched.group(2).strip()
                continue
            if key is not None and line.strip():
                fields[key] = f"{fields[key]} {line.strip()}".strip()
        return {name: value.lstrip("|>").strip() for name, value in fields.items()}

    manifest = json.load(open(sys.argv[1], encoding="utf-8"))
    violations = []

    for skill_id, source in sorted(manifest.items()):
        path = f"{source}/SKILL.md"
        try:
            lines = open(path, encoding="utf-8").read().split("\n")
        except OSError as error:
            violations.append(f"{skill_id}: SKILL.md を読めない: {error}")
            continue
        fields = frontmatter(lines)
        if fields is None:
            violations.append(f"{skill_id}: YAML frontmatter がない")
            continue
        if fields.get("name") != skill_id:
            violations.append(
                f"{skill_id}: frontmatter name が directory 名と一致しない: {fields.get('name')!r}"
            )
        if not fields.get("description"):
            violations.append(f"{skill_id}: description が空")

    if violations:
        print("\n".join(violations), file=sys.stderr)
        raise SystemExit(1)
  '';
in
{
  # local Skill と plugin 由来 Skill を同じ contract で検査する。source の出所で分岐しない
  skill-frontmatter-contract =
    pkgs.runCommandLocal "check-skill-frontmatter-contract"
      {
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        python3 ${validator} ${manifest}
        touch $out
      '';
}
