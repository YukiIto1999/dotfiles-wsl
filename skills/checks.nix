{
  pkgs,
  lib,
  hostConfig,
  mkNixosSystem,
  normalMachineModule,
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
  containerCapabilityIds = [
    "code-quality"
    "project-memory"
    "web-content"
    "web-discovery"
  ];
  containerlessCapabilityIds = builtins.filter (
    name: !builtins.elem name containerCapabilityIds
  ) hostConfig.dotfiles.capabilities.enabled;
  containerlessConfig =
    (mkNixosSystem [
      normalMachineModule
      (
        { lib, ... }:
        {
          dotfiles.capabilities.enabled = lib.mkForce containerlessCapabilityIds;
        }
      )
    ]).config;
  enabledSkills = containerlessConfig.dotfiles.skills.enabled;
  containerlessRegistry = containerlessConfig.dotfiles.skills.registry;
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

  skill-capability-gating =
    assert builtins.elem "repository-research" enabledSkills;
    assert builtins.elem "code-review" enabledSkills;
    assert !builtins.elem "memory" enabledSkills;
    assert !builtins.elem "web-research" enabledSkills;
    assert containerlessRegistry."code-review".requiresCapabilities == [ ];
    assert builtins.elem "code-quality" containerlessRegistry."code-review".optionalCapabilities;
    assert !builtins.elem "code-quality" containerlessConfig.dotfiles.capabilities.resolved;
    assert lib.all (
      name:
      lib.all (
        capability: builtins.elem capability containerlessConfig.dotfiles.capabilities.resolved
      ) containerlessRegistry.${name}.requiresCapabilities
    ) enabledSkills;
    assert lib.all (
      name:
      lib.all (
        dependency: builtins.elem dependency enabledSkills
      ) containerlessRegistry.${name}.requiresSkills
    ) enabledSkills;
    pkgs.runCommandLocal "check-skill-capability-gating" { } "touch $out";
}
