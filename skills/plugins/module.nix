{
  config,
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
        property-testing = {
          requiresCapabilities = [ ];
          requiresSkills = [ "standard-apply" ];
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
          requiresCapabilities = [ ];
          requiresSkills = [ ];
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
        grill-with-docs = {
          directory = "skills/engineering/grill-with-docs";
          requiresCapabilities = [ ];
          requiresSkills = [
            "grilling"
            "domain-modeling"
          ];
        };
        grill-me = {
          directory = "skills/productivity/grill-me";
          requiresCapabilities = [ ];
          requiresSkills = [ "grilling" ];
        };
        to-spec = {
          directory = "skills/engineering/to-spec";
          requiresCapabilities = [ ];
          requiresSkills = [ "setup-matt-pocock-skills" ];
        };
        to-tickets = {
          directory = "skills/engineering/to-tickets";
          requiresCapabilities = [ ];
          requiresSkills = [ "setup-matt-pocock-skills" ];
        };
        prototype = {
          directory = "skills/engineering/prototype";
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
        retro = {
          directory = "skills/engineering/retro";
          requiresCapabilities = [ ];
          requiresSkills = [ "writing-for-agents" ];
        };
        writing-for-agents = {
          directory = "skills/productivity/writing-for-agents";
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
      };
    };
    chrome-devtools = {
      source = pluginSources.chrome-devtools;
      skills = {
        a11y-debugging = {
          requiresCapabilities = [ "browser-diagnostics" ];
          requiresSkills = [ ];
        };
        debug-optimize-lcp = {
          requiresCapabilities = [ "browser-diagnostics" ];
          requiresSkills = [ ];
        };
      };
    };
    dotnet = {
      source = pluginSources.dotnet;
      skills = {
        msbuild = {
          directory = "plugins/dotnet/skills/msbuild";
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
        run-tests = {
          directory = "plugins/dotnet-test/skills/run-tests";
          requiresCapabilities = [ ];
          requiresSkills = [
            "platform-detection"
            "filter-syntax"
          ];
        };
        platform-detection = {
          directory = "plugins/dotnet-test/skills/platform-detection";
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
        filter-syntax = {
          directory = "plugins/dotnet-test/skills/filter-syntax";
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
        microbenchmarking = {
          directory = "plugins/dotnet-diag/skills/microbenchmarking";
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
        nuget-trusted-publishing = {
          directory = "plugins/dotnet-advanced/skills/nuget-trusted-publishing";
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

  config.home-manager.users.${config.dotfiles.workstation.username}.home.file.".local/share/dotfiles-agent/references/modern-web-guidance".source =
    pluginSources.modern-web-guidance;
  config.dotfiles.managedArtifacts."skills/references/modern-web-guidance" = {
    format = "directory";
    source = pluginSources.modern-web-guidance;
    deployedAt = "${config.dotfiles.workstation.homeDir}/.local/share/dotfiles-agent/references/modern-web-guidance";
  };

  config.assertions = [
    {
      assertion = duplicatePluginSkills == [ ];
      message = "Duplicate Skill IDs across plugins: ${lib.concatStringsSep ", " duplicatePluginSkills}";
    }
  ];
}
