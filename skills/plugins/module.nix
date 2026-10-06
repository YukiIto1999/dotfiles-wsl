{
  lib,
  pluginSources,
  ...
}:

let
  # upstream の追加による採用集合の暗黙変更を防ぐため directory の自動列挙は不採用
  adoptedPluginSkills = {
    orca = {
      source = pluginSources.orca;
      skills = {
        orca-cli = {
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
        orchestration = {
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
        computer-use = {
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
        orca-emulator = {
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
        orca-emulator-android = {
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
        orca-linear = {
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
        orca-per-workspace-env = {
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
      };
    };
    architecture-standard = {
      source = pluginSources.architecture-standard;
      skills = {
        standard-apply = {
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
        standard-audit = {
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
        standard-conformance = {
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
        standard-feedback = {
          requiresCapabilities = [ "github-resources" ];
          requiresSkills = [ ];
        };
        standard-update = {
          requiresCapabilities = [ ];
          requiresSkills = [
            "standard-audit"
            "web-research"
          ];
        };
      };
    };
    matt-pocock = {
      source = pluginSources.matt-pocock;
      skills = {
        codebase-design = {
          directory = "skills/engineering/codebase-design";
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
        diagnosing-bugs = {
          directory = "skills/engineering/diagnosing-bugs";
          requiresCapabilities = [ "browser-diagnostics" ];
          requiresSkills = [
            "browser-operation"
            "improve-codebase-architecture"
          ];
        };
        tdd = {
          directory = "skills/engineering/tdd";
          requiresCapabilities = [ ];
          requiresSkills = [
            "codebase-design"
            "code-review"
          ];
        };
        domain-modeling = {
          directory = "skills/engineering/domain-modeling";
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
        grilling = {
          directory = "skills/productivity/grilling";
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
        code-review = {
          directory = "skills/engineering/code-review";
          requiresCapabilities = [ ];
          requiresSkills = [ "setup-matt-pocock-skills" ];
        };
        improve-codebase-architecture = {
          directory = "skills/engineering/improve-codebase-architecture";
          requiresCapabilities = [ ];
          requiresSkills = [
            "codebase-design"
            "domain-modeling"
            "grilling"
          ];
        };
        setup-matt-pocock-skills = {
          directory = "skills/engineering/setup-matt-pocock-skills";
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
        research = {
          directory = "skills/engineering/research";
          requiresCapabilities = [ ];
          requiresSkills = [ "web-research" ];
        };
      };
    };
    ponytail = {
      source = pluginSources.ponytail;
      skills = {
        ponytail = {
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
        ponytail-review = {
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
      };
    };
  };
  pluginSourceNames = builtins.attrNames adoptedPluginSkills;
  pluginSkillNames = lib.concatMap (
    sourceName: builtins.attrNames adoptedPluginSkills.${sourceName}.skills
  ) pluginSourceNames;
  duplicatePluginSkills = lib.unique (
    builtins.filter (
      name: lib.count (candidate: candidate == name) pluginSkillNames > 1
    ) pluginSkillNames
  );
  pluginSkills = lib.concatMapAttrs (
    _: source:
    lib.mapAttrs (
      skillId: metadata:
      builtins.removeAttrs metadata [ "directory" ]
      // {
        source = source.source + "/${metadata.directory or "skills/${skillId}"}";
      }
    ) source.skills
  ) adoptedPluginSkills;
in
{
  config.dotfiles.skills.registry = pluginSkills;

  config.assertions = [
    {
      assertion = duplicatePluginSkills == [ ];
      message = "Duplicate Skill IDs across plugins: ${lib.concatStringsSep ", " duplicatePluginSkills}";
    }
  ];
}
