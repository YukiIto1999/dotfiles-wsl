{
  config,
  lib,
  pkgs,
  pluginSources,
  ...
}:

let
  cfg = config.dotfiles;
  mkCommand = import ../commands/impl/mk-command.nix { inherit config lib pkgs; };
  inherit (cfg) agents;
  agentContract = import ./impl/contract.nix { inherit lib; };
  clientNames = builtins.attrNames agents.clients;
  runtime = import ./package.nix { inherit lib pkgs runtimeContract; };
  runtimeWrapperDirectory = ".local/share/dotfiles-agent/bin";
  runtimeClientNames = builtins.filter (
    name: name != "antigravity" && agents.clients.${name}.binary != ""
  ) clientNames;
  runtimeWrappers = lib.listToAttrs (
    map (
      name:
      let
        client = agents.clients.${name};
        wrapper = runtime.mkWrapper {
          client = name;
          inherit (client) binary;
          homeDir = cfg.host.homeDir;
        };
      in
      lib.nameValuePair "${runtimeWrapperDirectory}/${client.binary}" {
        source = lib.getExe wrapper;
        executable = true;
      }
    ) runtimeClientNames
  );

  pluginPaths = [
    pluginSources.superpowers
    (pluginSources.openai-plugins + "/plugins/codex-security")
    (pluginSources.claude-plugins-official + "/plugins/frontend-design")
    (pluginSources.claude-plugins-official + "/plugins/skill-creator")
  ];

  findSkillsIn =
    pluginPath:
    let
      skillsRoot = pluginPath + "/skills";
      entries = if builtins.pathExists skillsRoot then builtins.readDir skillsRoot else { };
    in
    lib.mapAttrs' (name: _: lib.nameValuePair name (skillsRoot + "/${name}")) (
      lib.filterAttrs (
        name: type: type == "directory" && builtins.pathExists (skillsRoot + "/${name}/SKILL.md")
      ) entries
    );

  pluginSkills = lib.foldl' (skills: path: skills // findSkillsIn path) { } pluginPaths;
  pluginSkillNames = lib.concatMap (path: builtins.attrNames (findSkillsIn path)) pluginPaths;
  pluginSkillDupes = lib.unique (
    builtins.filter (
      name: lib.count (candidate: candidate == name) pluginSkillNames > 1
    ) pluginSkillNames
  );

  localSkillsRoot = ./shared/skills;
  localSkills = lib.mapAttrs' (name: _: lib.nameValuePair name (localSkillsRoot + "/${name}")) (
    lib.filterAttrs (
      name: type: type == "directory" && builtins.pathExists (localSkillsRoot + "/${name}/SKILL.md")
    ) (builtins.readDir localSkillsRoot)
  );
  localVsPluginDupes = builtins.filter (name: builtins.hasAttr name pluginSkills) (
    builtins.attrNames localSkills
  );
  allSkills = pluginSkills // localSkills;

  definitionsRoot = ./shared/definitions;
  sharedDefinitions =
    lib.mapAttrs'
      (
        filename: _: lib.nameValuePair (lib.removeSuffix ".md" filename) (definitionsRoot + "/${filename}")
      )
      (
        lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".md" name) (
          builtins.readDir definitionsRoot
        )
      );

  definitionFileName =
    client: name:
    if client.definitionMode == "rendered" && client.definitionFormat == "toml" then
      "${name}.toml"
    else
      "${name}.md";

  normalizeSource =
    source:
    if builtins.typeOf source == "path" then
      builtins.path {
        path = source;
        name = builtins.baseNameOf (toString source);
      }
    else
      source;

  sharedDeploymentRows = lib.concatMap (
    clientName:
    let
      client = agents.clients.${clientName};
      definitionRows = lib.optionals (client.definitionMode != "unsupported") (
        lib.mapAttrsToList (name: source: {
          inherit clientName;
          id = "definitions/${name}";
          file = {
            inherit source;
            format = if client.definitionFormat == "toml" then "toml" else "markdown";
            deployment = "home";
            destination = "${client.definitionsDestination}/${definitionFileName client name}";
          };
        }) client.definitions
      );
    in
    [
      {
        inherit clientName;
        id = "rules";
        file = {
          source = agents.shared.rules;
          format = "markdown";
          deployment = "home";
          destination = client.rulesDestination;
        };
      }
    ]
    ++ lib.mapAttrsToList (name: source: {
      inherit clientName;
      id = "skills/${name}";
      file = {
        inherit source;
        format = "directory";
        deployment = "home";
        destination = "${client.skillsDestination}/${name}";
      };
    }) agents.shared.skills
    ++ definitionRows
  ) clientNames;

  managedFileRows = lib.concatMap (
    clientName:
    lib.mapAttrsToList (id: file: {
      inherit clientName id file;
    }) agents.clients.${clientName}.managedFiles
  ) clientNames;

  deploymentRows = map (
    row:
    row
    // {
      file = row.file // {
        source = normalizeSource row.file.source;
      };
    }
  ) (sharedDeploymentRows ++ managedFileRows);

  homeManagedEntries = map (
    row: lib.nameValuePair row.file.destination { source = row.file.source; }
  ) (builtins.filter (row: row.file.deployment == "home") deploymentRows);

  systemManagedEntries = map (
    row: lib.nameValuePair row.file.destination { source = row.file.source; }
  ) (builtins.filter (row: row.file.deployment == "system") deploymentRows);

  seedRows = builtins.filter (row: row.file.deployment == "seed") deploymentRows;

  seedScript = lib.concatMapStrings (
    row:
    let
      target = "${cfg.host.homeDir}/${row.file.destination}";
    in
    ''
      target=${lib.escapeShellArg target}
      if [ ! -e "$target" ] && [ ! -L "$target" ]; then
        install -Dm600 ${lib.escapeShellArg (toString row.file.source)} "$target"
      fi
      ${lib.optionalString (row.file.seedMigrationCommand != null) ''
        ${lib.getExe row.file.seedMigrationCommand} "$target" ${lib.escapeShellArg cfg.host.homeDir} || exit $?
      ''}
    ''
  ) seedRows;

  managedArtifacts = lib.listToAttrs (
    map (
      row:
      lib.nameValuePair "agents/${row.clientName}/${row.id}" (
        {
          inherit (row.file) format;
          source = row.file.source;
        }
        // lib.optionalAttrs (row.file.deployment == "system") {
          deployedAt = "/etc/${row.file.destination}";
        }
        // lib.optionalAttrs (row.file.deployment == "home") {
          deployedAt = "${cfg.host.homeDir}/${row.file.destination}";
        }
      )
    ) deploymentRows
  );

  installRecord =
    name:
    let
      client = agents.clients.${name};
    in
    {
      inherit name;
      inherit (client) binary versionArgs;
      inherit (client) install;
    };

  installManifest = builtins.toJSON (map installRecord clientNames);
  atomicPublish = import ./impl/atomic-publish.nix { inherit pkgs; };

  installAgents = mkCommand {
    name = "dotfiles-install-agents";
    src = ./impl/install-agents.sh;
    vars = {
      inherit installManifest;
      atomicPublishCommand = lib.escapeShellArg (
        lib.getExe' atomicPublish "dotfiles-agent-atomic-publish"
      );
      probeEnvironment = "";
      transactionHookCommand = lib.escapeShellArg "${pkgs.coreutils}/bin/true";
      versionArgsDecoder = builtins.readFile ./impl/version-args.sh;
    };
    runtimeInputs = with pkgs; [
      atomicPublish
      bash
      curl
      diffutils
      findutils
      gawk
      jq
      gnutar
      gzip
      coreutils
      util-linux
    ];
  };
  apm = pkgs.callPackage ./package/apm.nix { };

  allHomeEntries = homeManagedEntries;
  homeDestinations = map (entry: entry.name) allHomeEntries;
  seedDestinations = map (row: row.file.destination) seedRows;
  systemDestinations = map (entry: entry.name) systemManagedEntries;

  runtimeContract =
    let
      observationTimeoutSeconds = 10;
      relativeCacheRoot = ".cache/dotfiles-wsl";
      relativeStateRoot = ".local/state/dotfiles-wsl";
      releaseFor =
        client:
        if pkgs.stdenv.hostPlatform.isAarch64 then
          client.install.releaseByArch.aarch64
        else
          client.install.releaseByArch.x86_64;
      commonObservation = checkId: resourceKey: failureMessage: {
        inherit checkId resourceKey failureMessage;
        timeoutSeconds = observationTimeoutSeconds;
      };
      timerObservation = timer: {
        kind = "systemd-timer";
        checkId = "maintenance/${timer.name}.timer";
        resourceKey = null;
        timeoutSeconds = observationTimeoutSeconds;
        failureMessage = "${timer.name}.timer or its service is not operational";
        timer = "${timer.name}.timer";
        service = "${timer.name}.service";
        unitFileStates = [
          "enabled"
          "enabled-runtime"
        ];
        activeStates = [ "active" ];
        serviceResults = [ "success" ];
      };
      clientObservation =
        name: client:
        let
          visiblePath = "${cfg.host.homeDir}/.local/bin/${client.binary}";
          releaseRoot = "${cfg.host.homeDir}/.local/share/dotfiles/agents/${name}";
        in
        commonObservation "agent/${name}" null
          "${client.binary} is unavailable or its version command failed"
        // (
          if client.install.kind == "github-release" then
            let
              release = releaseFor client;
            in
            {
              kind = "release-tree";
              inherit visiblePath;
              visibleTarget = "../share/dotfiles/agents/${name}/current/${release.entrypoint}";
              currentLink = "${releaseRoot}/current";
              releasesRoot = "${releaseRoot}/releases";
              inherit (release) entrypoint;
              inherit (client.install) requiredPaths;
              inherit (client) versionArgs;
            }
          else
            {
              kind = "command-version";
              path = visiblePath;
              expectedSource = visiblePath;
              inherit (client) versionArgs;
            }
        );
    in
    rec {
      ledgerRetentionDays = agents.runtime.ledgerRetentionDays;
      cache = rec {
        inherit relativeCacheRoot;
        root = "${cfg.host.homeDir}/${relativeCacheRoot}";
        buildsRoot = "${root}/builds";
        sharedRoot = "${root}/shared";
        sessionsRoot = "${root}/sessions";
        verificationRoot = "${root}/verification";
        highBytes = 68719476736;
        lowBytes = 51539607552;
        inactiveDays = 30;
      };
      state = rec {
        inherit relativeStateRoot;
        root = "${cfg.host.homeDir}/${relativeStateRoot}";
        relativeResourcesRoot = "${relativeStateRoot}/agent-resources";
        resourcesRoot = "${cfg.host.homeDir}/${relativeResourcesRoot}";
      };
      timers = {
        autoupdate = {
          name = "dotfiles-agent-autoupdate";
          onCalendar = "daily";
          persistent = true;
        };
        projectCacheGc = {
          name = "dotfiles-agent-project-cache-gc";
          onCalendar = "daily";
          persistent = true;
        };
        resourceReaper = {
          name = "dotfiles-agent-resource-reaper";
          onCalendar = "hourly";
          persistent = true;
        };
      };
      packages = {
        inherit installAgents;
        inherit (runtime)
          agentResource
          agentWorktree
          gc
          launcher
          verify
          ;
      };
      commands = {
        autoupdate = lib.getExe packages.installAgents;
        projectCacheGc = lib.getExe packages.gc;
        resourceReaper = "${lib.getExe packages.agentResource} reap";
      };
      observations = {
        "agents/roster" = commonObservation "agent-roster" null "agent roster is empty" // {
          kind = "roster";
          members = agents.enabled;
          minimumCount = 1;
          failureOnly = true;
        };
        "agents/managed-roots" =
          commonObservation "resource/managed-roots" "managedRoots"
            "could not summarize every managed resource root"
          // {
            kind = "managed-roots";
            paths = [
              cache.buildsRoot
              cache.sharedRoot
              cache.sessionsRoot
              state.resourcesRoot
            ];
            missingAsZero = true;
            oneFileSystem = true;
            cachePolicy = "allocated-bytes";
          };
        "agents/maintenance/project-cache-gc" = timerObservation timers.projectCacheGc;
        "agents/maintenance/resource-reaper" = timerObservation timers.resourceReaper;
      }
      // lib.mapAttrs' (
        name: client: lib.nameValuePair "agents/client/${name}" (clientObservation name client)
      ) (lib.filterAttrs (_: client: client.binary != "") agents.clients);
    };
in
{
  options.dotfiles.agents = agentContract.options;

  config = {
    dotfiles.agents = {
      packages = {
        inherit apm;
        agentmemoryHooks = config.dotfiles.agents.agentmemory.hooks;
        projectCacheGc = runtimeContract.packages.gc;
        verification = runtimeContract.packages.verify;
      };
      stateRoot = "~/${runtimeContract.state.relativeResourcesRoot}";
      inherit (runtimeContract.packages) agentResource agentWorktree;
      runtime = {
        inherit (runtimeContract) timers;
        cache = builtins.removeAttrs runtimeContract.cache [ "relativeCacheRoot" ];
        state = builtins.removeAttrs runtimeContract.state [
          "relativeStateRoot"
          "relativeResourcesRoot"
        ];
      };
      shared = {
        rules = ./shared/AGENTS.md;
        skills = allSkills;
        definitions = sharedDefinitions;
      };
    };

    dotfiles.artifacts = managedArtifacts;
    dotfiles.observations = runtimeContract.observations;
    dotfiles.commands = {
      inherit (runtimeContract.packages) installAgents agentResource agentWorktree;
    };

    assertions = agentContract.assertionsFor agents ++ [
      {
        assertion = localVsPluginDupes == [ ];
        message = "Duplicate skill names between local and plugins: ${lib.concatStringsSep ", " localVsPluginDupes}";
      }
      {
        assertion = pluginSkillDupes == [ ];
        message = "Duplicate skill names across plugins: ${lib.concatStringsSep ", " pluginSkillDupes}";
      }
      {
        assertion = homeDestinations == lib.unique homeDestinations;
        message = "Agent home destinations must be unique";
      }
      {
        assertion = systemDestinations == lib.unique systemDestinations;
        message = "Agent system destinations must be unique";
      }
      {
        assertion = seedDestinations == lib.unique seedDestinations;
        message = "Agent seed destinations must be unique";
      }
      {
        assertion = lib.intersectLists seedDestinations homeDestinations == [ ];
        message = "Agent seed and Home Manager destinations must not overlap";
      }
      {
        assertion = runtimeContract.cache.lowBytes < runtimeContract.cache.highBytes;
        message = "Agent cache low watermark must be below the high watermark";
      }
      {
        assertion =
          map (timer: timer.name) (builtins.attrValues runtimeContract.timers)
          == lib.unique (map (timer: timer.name) (builtins.attrValues runtimeContract.timers));
        message = "Agent runtime timer names must be unique";
      }
    ];

    environment.etc = lib.listToAttrs systemManagedEntries;
    environment.systemPackages = [
      config.dotfiles.agents.packages.agentmemoryHooks
      config.dotfiles.agents.packages.projectCacheGc
      config.dotfiles.agents.packages.verification
    ];

    home-manager.users.${cfg.host.username} =
      { lib, ... }:
      {
        home.packages = [ apm ];
        home.file = lib.mkMerge [
          (lib.listToAttrs allHomeEntries)
          runtimeWrappers
        ];
        home.sessionPath = lib.mkBefore [ "$HOME/${runtimeWrapperDirectory}" ];
        home.activation.seedAgentConfigs = lib.hm.dag.entryAfter [ "writeBoundary" ] seedScript;
      };

    systemd.services.${runtimeContract.timers.autoupdate.name} = {
      description = "Agent client を latest へ更新";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = cfg.host.username;
        Environment = [
          "HOME=${cfg.host.homeDir}"
          "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
        ];
        ExecStart = runtimeContract.commands.autoupdate;
      };
    };

    systemd.timers.${runtimeContract.timers.autoupdate.name} = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = runtimeContract.timers.autoupdate.onCalendar;
        Persistent = runtimeContract.timers.autoupdate.persistent;
      };
    };

    systemd.services.${runtimeContract.timers.projectCacheGc.name} = {
      description = "Agent cache を容量制御";
      serviceConfig = {
        Type = "oneshot";
        User = cfg.host.username;
        Environment = "HOME=${cfg.host.homeDir}";
        ExecStart = runtimeContract.commands.projectCacheGc;
      };
    };

    systemd.timers.${runtimeContract.timers.projectCacheGc.name} = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = runtimeContract.timers.projectCacheGc.onCalendar;
        Persistent = runtimeContract.timers.projectCacheGc.persistent;
      };
    };

    systemd.services.${runtimeContract.timers.resourceReaper.name} = {
      description = "Reap inactive agent-owned linked worktrees";
      serviceConfig = {
        Type = "oneshot";
        User = cfg.host.username;
        Environment = "HOME=${cfg.host.homeDir}";
        UMask = "0077";
        ExecStart = runtimeContract.commands.resourceReaper;
      };
    };

    systemd.timers.${runtimeContract.timers.resourceReaper.name} = {
      description = "Hourly agent resource ownership reaper";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = runtimeContract.timers.resourceReaper.onCalendar;
        Persistent = runtimeContract.timers.resourceReaper.persistent;
        Unit = "${runtimeContract.timers.resourceReaper.name}.service";
      };
    };
  };
}
