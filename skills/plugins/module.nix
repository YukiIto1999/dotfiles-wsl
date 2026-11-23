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
          requiresSkills = [ "standard-audit" ];
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
        diagnosing-bugs = {
          directory = "skills/engineering/diagnosing-bugs";
          requiresCapabilities = [ ];
          requiresSkills = [ ];
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
        setup-matt-pocock-skills = {
          directory = "skills/engineering/setup-matt-pocock-skills";
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
        codebase-design = {
          directory = "skills/engineering/codebase-design";
          requiresCapabilities = [ ];
          requiresSkills = [ ];
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
        grill-with-docs = {
          directory = "skills/engineering/grill-with-docs";
          requiresCapabilities = [ ];
          requiresSkills = [
            "grilling"
            "domain-modeling"
          ];
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
    pstack = {
      source = pluginSources.pstack;
      skills = {
        benchmark-checklist = {
          directory = "pstack/skills/benchmark-checklist";
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
        correct = {
          directory = "pstack/skills/correct";
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
        maintain-verification-skill = {
          directory = "pstack/skills/maintain-verification-skill";
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
        # TLA+ の検査結果は statechart で読む手順のため、相対参照先の statechart を同じ固定 source から配備する
        create-formal-verification-skill = {
          directory = "pstack/skills/create-formal-verification-skill";
          requiresCapabilities = [ ];
          requiresSkills = [ "statechart" ];
        };
        maintain-formal-verification-skill = {
          directory = "pstack/skills/maintain-formal-verification-skill";
          requiresCapabilities = [ ];
          requiresSkills = [ ];
        };
        statechart = {
          directory = "pstack/skills/statechart";
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
          optionalCapabilities = [ "build-diagnostics" ];
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
    explainer = {
      source = pluginSources.explainer;
      skills = {
        explainer = {
          requiresCapabilities = [ ];
          requiresSkills = [ "first-reader" ];
        };
        explainer-book = {
          requiresCapabilities = [ ];
          requiresSkills = [ "explainer" ];
        };
        first-reader = {
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
