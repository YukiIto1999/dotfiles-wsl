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
  externalSkill = {
    source = ./fixtures/external-source/procedures/external-procedure;
    requiresCapabilities = [ "browser-automation" ];
    requiresSkills = [ "code-design" ];
  };
  replacementSkill = {
    source = ./fixtures/external-source/procedures/bug-analysis;
    requiresCapabilities = [ ];
    requiresSkills = [ ];
  };
  sourceAdoptionModule = {
    dotfiles.skills.registry = {
      external-procedure = externalSkill;
      bug-analysis = lib.mkForce replacementSkill;
    };
  };
  sourceConfig =
    (mkNixosSystem [
      normalMachineModule
      sourceAdoptionModule
    ]).config;
  sourceManifest = pkgs.writeText "skill-source-manifest.json" (
    builtins.toJSON {
      external-procedure = "${sourceConfig.dotfiles.agents.shared.skills.external-procedure}";
      bug-analysis = "${sourceConfig.dotfiles.agents.shared.skills.bug-analysis}";
    }
  );
  mismatchedManifest = pkgs.writeText "skill-mismatched-name-manifest.json" (
    builtins.toJSON { renamed-procedure = "${externalSkill.source}"; }
  );
  evaluateSkills =
    resolved: modules:
    (lib.evalModules {
      modules = [
        ./module.nix
        ./browser-operation/module.nix
        ./bug-analysis/module.nix
        ./code-design/module.nix
        {
          options = {
            assertions = lib.mkOption {
              type = lib.types.listOf lib.types.raw;
              default = [ ];
            };
            dotfiles.capabilities.registry = lib.mkOption {
              type = lib.types.attrsOf lib.types.raw;
              default = {
                browser-automation = { };
              };
            };
            dotfiles.capabilities.resolved = lib.mkOption {
              type = lib.types.listOf lib.types.str;
            };
          };
          config.dotfiles.capabilities.resolved = resolved;
        }
      ]
      ++ modules;
    }).config;
  sourceContractPasses =
    modules:
    let
      config = evaluateSkills [ "browser-automation" ] modules;
      result = builtins.tryEval (
        builtins.deepSeq config.dotfiles.skills.registry (
          builtins.deepSeq config.assertions (lib.all (entry: entry.assertion) config.assertions)
        )
      );
    in
    result.success && result.value;
  rejectedSources = [
    (externalSkill.source + "/missing")
    (externalSkill.source + "/SKILL.md")
    ./fixtures/invalid-source
  ];
  noCapabilitiesBefore =
    evaluateSkills
      [ ]
      [
        { dotfiles.skills.registry.external-procedure = externalSkill; }
      ];
  noCapabilitiesAfter = evaluateSkills [ ] [ sourceAdoptionModule ];
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
                f"{skill_id}: frontmatter name が registry ID と一致しない: {fields.get('name')!r}"
            )
        if not fields.get("description"):
            violations.append(f"{skill_id}: description が空")

    if violations:
        print("\n".join(violations), file=sys.stderr)
        raise SystemExit(1)
  '';
  containerCapabilityIds = [
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
  skill-source-contract =
    assert sourceContractPasses [ sourceAdoptionModule ];
    assert lib.all (
      source:
      !(sourceContractPasses [
        {
          dotfiles.skills.registry.external-procedure = externalSkill // {
            inherit source;
          };
        }
      ])
    ) rejectedSources;
    assert
      !(sourceContractPasses [
        { dotfiles.skills.registry."Unsafe_ID" = externalSkill; }
      ]);
    assert
      !(sourceContractPasses [
        {
          dotfiles.skills.registry.external-procedure = externalSkill // {
            requiresCapabilities = [ "missing-capability" ];
          };
        }
      ]);
    assert
      !(sourceContractPasses [
        {
          dotfiles.skills.registry.external-procedure = externalSkill // {
            requiresSkills = [ "missing-skill" ];
          };
        }
      ]);
    assert
      !(sourceContractPasses [
        { dotfiles.skills.registry.external-procedure.source = externalSkill.source; }
      ]);
    assert
      !(sourceContractPasses [
        { dotfiles.skills.registry.bug-analysis = replacementSkill; }
      ]);
    assert
      !(sourceContractPasses [
        { dotfiles.skills.registry.bug-analysis.source = ./bug-analysis/skill; }
      ]);
    assert
      !(sourceContractPasses [
        sourceAdoptionModule
        { dotfiles.skills.registry.bug-analysis = lib.mkForce replacementSkill; }
      ]);
    assert !builtins.elem "bug-analysis" noCapabilitiesBefore.dotfiles.skills.enabled;
    assert builtins.elem "bug-analysis" noCapabilitiesAfter.dotfiles.skills.enabled;
    assert !builtins.elem "external-procedure" noCapabilitiesAfter.dotfiles.skills.enabled;
    assert noCapabilitiesAfter.dotfiles.skills.registry.bug-analysis.requiresSkills == [ ];
    assert
      toString sourceConfig.dotfiles.agents.shared.skills.bug-analysis
      == toString replacementSkill.source;
    assert
      toString sourceConfig.dotfiles.agents.shared.skills.external-procedure
      == toString externalSkill.source;
    assert
      toString sourceConfig.dotfiles.agents.shared.skills.bug-analysis
      != toString hostConfig.dotfiles.skills.registry.bug-analysis.source;
    pkgs.runCommandLocal "check-skill-source-contract"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.gnugrep
          pkgs.python3
        ];
      }
      ''
        set -euo pipefail
        python3 ${validator} ${sourceManifest}
        source=${sourceConfig.dotfiles.agents.shared.skills.external-procedure}
        test "$(cat "$source/references/contract.txt")" = "External source reference fixture."
        test "$(bash "$source/scripts/read-reference.sh")" = "External source reference fixture."
        if python3 ${validator} ${mismatchedManifest} >frontmatter-error 2>&1; then
          echo "mismatched registry ID unexpectedly passed" >&2
          exit 1
        fi
        grep -F "frontmatter name が registry ID と一致しない" frontmatter-error
        touch $out
      '';

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
