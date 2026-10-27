{
  configuration = [
    (
      {
        pkgs,
        lib,
        hostConfig,
        mkProbeSystem,
        normalMachineModule,
        projectMemoryDisabledConfig,
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
          requiresSkills = [ "codebase-design" ];
        };
        replacementSkill = {
          source = ./fixtures/external-source/procedures/browser-operation;
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
        sourceAdoptionModule = {
          dotfiles.skills.registry = {
            external-procedure = externalSkill;
            browser-operation = lib.mkForce replacementSkill;
          };
        };
        sourceConfig =
          (mkProbeSystem [
            normalMachineModule
            sourceAdoptionModule
          ]).config;
        sourceManifest = pkgs.writeText "skill-source-manifest.json" (
          builtins.toJSON {
            external-procedure = "${sourceConfig.dotfiles.agents.shared.skills.external-procedure}";
            browser-operation = "${sourceConfig.dotfiles.agents.shared.skills.browser-operation}";
          }
        );
        mismatchedManifest = pkgs.writeText "skill-mismatched-name-manifest.json" (
          builtins.toJSON { renamed-procedure = "${externalSkill.source}"; }
        );
        evaluateSkills =
          resolved: modules:
          (lib.evalModules {
            modules = [
              ./impl/contract.nix
              ./browser-operation/module.nix
              { dotfiles.skills.registry.codebase-design = registry.codebase-design; }
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
        optionalSkill = externalSkill // {
          requiresCapabilities = [ ];
          optionalCapabilities = [ "browser-automation" ];
        };
        optionalCapabilityAbsent =
          evaluateSkills
            [ ]
            [
              { dotfiles.skills.registry.external-procedure = optionalSkill; }
            ];
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
        enabledSkills = projectMemoryDisabledConfig.dotfiles.skills.enabled;
        containerlessRegistry = projectMemoryDisabledConfig.dotfiles.skills.registry;
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
                dotfiles.skills.registry.external-procedure = optionalSkill // {
                  optionalCapabilities = [ "missing-capability" ];
                };
              }
            ]);
          assert
            !(sourceContractPasses [
              {
                dotfiles.skills.registry.external-procedure = optionalSkill // {
                  optionalCapabilities = [
                    "browser-automation"
                    "browser-automation"
                  ];
                };
              }
            ]);
          assert builtins.elem "external-procedure" optionalCapabilityAbsent.dotfiles.skills.enabled;
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
              { dotfiles.skills.registry.browser-operation = replacementSkill; }
            ]);
          assert
            !(sourceContractPasses [
              { dotfiles.skills.registry.browser-operation.source = ./browser-operation/skill; }
            ]);
          assert
            !(sourceContractPasses [
              sourceAdoptionModule
              { dotfiles.skills.registry.browser-operation = lib.mkForce replacementSkill; }
            ]);
          assert builtins.elem "browser-operation" noCapabilitiesBefore.dotfiles.skills.enabled;
          assert !builtins.elem "external-procedure" noCapabilitiesBefore.dotfiles.skills.enabled;
          assert builtins.elem "browser-operation" noCapabilitiesAfter.dotfiles.skills.enabled;
          assert !builtins.elem "external-procedure" noCapabilitiesAfter.dotfiles.skills.enabled;
          assert
            toString sourceConfig.dotfiles.agents.shared.skills.browser-operation
            == toString replacementSkill.source;
          assert
            toString sourceConfig.dotfiles.agents.shared.skills.external-procedure
            == toString externalSkill.source;
          assert
            toString sourceConfig.dotfiles.agents.shared.skills.browser-operation
            != toString hostConfig.dotfiles.skills.registry.browser-operation.source;
          pkgs.runCommandLocal "check-skill-source-contract"
            {
              nativeBuildInputs = [ pkgs.python3 ];
            }
            ''
              set -euo pipefail
              python3 ${validator} ${sourceManifest}
              if python3 ${validator} ${mismatchedManifest} >frontmatter-error 2>&1; then
                echo "mismatched registry ID unexpectedly passed" >&2
                exit 1
              fi
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
          assert builtins.elem "web-research" enabledSkills;
          assert lib.all (
            name:
            lib.all (
              capability: builtins.elem capability projectMemoryDisabledConfig.dotfiles.capabilities.resolved
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
    )
  ];
}
