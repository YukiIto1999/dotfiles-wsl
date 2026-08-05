{
  config,
  lib,
  pkgs,
  pluginSources,
  mkCommand,
  ...
}:

let
  cfg = config.my;
  inherit (cfg) agents;
  agentContract = import ./impl/contract.nix { inherit lib; };
  clientNames = builtins.attrNames agents.clients;

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

  sharedHomeEntries = lib.concatMap (
    clientName:
    let
      client = agents.clients.${clientName};
      definitionEntries = lib.optionals (client.definitionMode != "unsupported") (
        lib.mapAttrsToList (
          name: source:
          lib.nameValuePair "${client.definitionsDestination}/${definitionFileName client name}" {
            inherit source;
          }
        ) client.definitions
      );
    in
    [
      (lib.nameValuePair client.rulesDestination { source = agents.shared.rules; })
    ]
    ++ lib.mapAttrsToList (
      name: source: lib.nameValuePair "${client.skillsDestination}/${name}" { inherit source; }
    ) agents.shared.skills
    ++ definitionEntries
  ) clientNames;

  managedFileRows = lib.concatMap (
    clientName:
    lib.mapAttrsToList (id: file: {
      inherit clientName id file;
    }) agents.clients.${clientName}.managedFiles
  ) clientNames;

  homeManagedEntries = map (
    row: lib.nameValuePair row.file.destination { source = row.file.source; }
  ) (builtins.filter (row: row.file.deployment == "home") managedFileRows);

  systemManagedEntries = map (
    row: lib.nameValuePair row.file.destination { source = row.file.source; }
  ) (builtins.filter (row: row.file.deployment == "system") managedFileRows);

  seedRows = builtins.filter (row: row.file.deployment == "seed") managedFileRows;

  seedScript = lib.concatMapStrings (
    row:
    let
      target = "${cfg.homeDir}/${row.file.destination}";
    in
    ''
      target=${lib.escapeShellArg target}
      if [ ! -e "$target" ] && [ ! -L "$target" ]; then
        install -Dm600 ${lib.escapeShellArg (toString row.file.source)} "$target"
      fi
    ''
  ) seedRows;

  artifactFormat =
    format:
    if
      builtins.elem format [
        "json"
        "toml"
        "yaml"
      ]
    then
      format
    else
      null;
  managedArtifacts = lib.listToAttrs (
    map (
      row:
      lib.nameValuePair "agents/${row.clientName}/${row.id}" (
        {
          format = artifactFormat row.file.format;
          source = row.file.source;
        }
        // lib.optionalAttrs (row.file.deployment == "system") {
          deployedAt = "/etc/${row.file.destination}";
        }
        // lib.optionalAttrs (row.file.deployment == "home") {
          deployedAt = "${cfg.homeDir}/${row.file.destination}";
        }
      )
    ) managedFileRows
  );

  installRecord =
    name:
    let
      client = agents.clients.${name};
    in
    {
      inherit name;
      inherit (client) binary versionArgs;
      install = lib.filterAttrs (_: value: value != null) client.install;
    };

  installManifest = builtins.toJSON (map installRecord clientNames);

  installAgents = mkCommand {
    name = "dotfiles-install-agents";
    src = ./impl/install-agents.sh;
    vars = {
      inherit installManifest;
      versionArgsDecoder = builtins.readFile ./impl/version-args.sh;
    };
    runtimeInputs = with pkgs; [
      bash
      curl
      jq
      gnutar
      gzip
      coreutils
    ];
  };

  allHomeEntries = sharedHomeEntries ++ homeManagedEntries;
  homeDestinations = map (entry: entry.name) allHomeEntries;
  seedDestinations = map (row: row.file.destination) seedRows;
  systemDestinations = map (entry: entry.name) systemManagedEntries;
in
{
  options.my.agents = agentContract.options;

  config = {
    my.agents.shared = {
      rules = ./shared/AGENTS.md;
      skills = allSkills;
      definitions = sharedDefinitions;
    };

    my.artifacts = managedArtifacts;
    my.commands.installAgents = installAgents;

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
    ];

    environment.etc = lib.listToAttrs systemManagedEntries;
    environment.systemPackages = [ config.dotfiles.containers.agentmemory.clients.hooks ];

    home-manager.users.${cfg.username} =
      { lib, ... }:
      {
        home.file = lib.listToAttrs allHomeEntries;
        home.activation.seedAgentConfigs = lib.hm.dag.entryAfter [ "writeBoundary" ] seedScript;
      };

    systemd.services.dotfiles-agent-autoupdate = {
      description = "Agent client を latest へ更新";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = cfg.username;
        Environment = [
          "HOME=${cfg.homeDir}"
          "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
        ];
        ExecStart = lib.getExe installAgents;
      };
    };

    systemd.timers.dotfiles-agent-autoupdate = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
      };
    };
  };
}
