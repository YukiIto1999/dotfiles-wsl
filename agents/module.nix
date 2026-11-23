{
  config,
  lib,
  pkgs,
  pluginSources,
  self,
  ...
}:

let
  cfg = config.dotfiles;
  projectMemoryEnabled = builtins.elem "project-memory" cfg.capabilities.resolved;
  mkCommand = import ../platform/cli/impl/mk-command.nix { inherit config lib pkgs; };
  policy = import ./impl/policy.nix { inherit lib pkgs; };
  isReferenceOnlySkill = import ./impl/skill-discovery.nix { inherit lib; };
  inherit (cfg) agents;
  agentContract = import ./impl/contract.nix { inherit lib; };
  inherit (agentContract)
    modeOf
    rulesDestinationOf
    constraintsDestinationOf
    subagentDestinationOf
    subagentSourcesOf
    ;
  rawRouting = import ./subagents/routing.nix;
  selectedClients = lib.genAttrs (builtins.filter (
    name: builtins.hasAttr name agents.registry
  ) agents.enabled) (name: agents.registry.${name});
  clientNames = builtins.attrNames agents.clients;

  # 供給元は flake.lock が採用した input と同じ参照から導き、baseline と更新で別の供給元を持たない
  profileRootRelative = ".local/share/dotfiles/agent-profiles";
  # 供給方式の切替前に旧 release writer が使った root。旧 writer との同時実行を避けるためだけに読む
  legacyRootRelative = ".local/share/dotfiles/agents";
  profileRoot = "${cfg.workstation.homeDir}/${profileRootRelative}";
  flakeLock = builtins.fromJSON (builtins.readFile ../flake.lock);
  supplyInput = flakeLock.nodes.llm-agents.original;
  supplySource = "${supplyInput.type}:${supplyInput.owner}/${supplyInput.repo}";
  supplyPackages = self.inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system};
  clientExecutables = lib.mapAttrs (
    name: client: "${profileRoot}/${name}/profile/bin/${client.binary}"
  ) agents.clients;
  supplyManifest = map (
    name:
    let
      client = agents.clients.${name};
    in
    {
      inherit name;
      inherit (client) binary versionArgs;
      inherit (client.supply) package;
      baseline = toString supplyPackages.${client.supply.package};
      automatic = builtins.elem name agents.automaticUpdates.clients;
    }
  ) clientNames;
  agentSupply = import ./impl/supply.nix { inherit lib pkgs mkCommand; } {
    manifest = supplyManifest;
    sourceRef = supplySource;
    homeDir = cfg.workstation.homeDir;
    inherit profileRootRelative legacyRootRelative;
  };
  toolSession = import ./impl/tool-session.nix { inherit lib pkgs mkCommand; } {
    clientExecutables = lib.mapAttrs (
      _: client: "${agents.lifecycle.wrapperDirectory}/${client.binary}"
    ) agents.clients;
    inherit (cfg.platform.mcp.gateway) optionalUrls;
    inherit (cfg.platform.mcp) privateServers;
  };

  runtime = import ./package.nix {
    inherit lib pkgs runtimeContract;
    verificationEntry = cfg.toolchain.verification.entry;
    executionPolicy = cfg.toolchain.execution.policy;
    supervise = cfg.platform.supervise.package;
    resourcePolicy = cfg.workstation.workload.admissionPolicy;
  };
  # 受入は session と同じ重みで CPU を分け合い、deep は他が使わない CPU だけを使う。memory の上限は agent の slice が持つ
  classSliceConfig = {
    acceptance.CPUWeight = 100;
    capped = cfg.workstation.workload.capped.sliceConfig;
    deep.CPUWeight = "idle";
  };
  runtimeWrapperDirectory = ".local/share/dotfiles-agent/bin";
  runtimeClientNames = builtins.filter (
    name: modeOf agents.clients.${name}.runtime == "managed"
  ) clientNames;
  /**
    session と job が固定する当該 client の不変な配備依存の列挙
    name: 採用済みの client ID
    戻り値: 初回 seed を除く重複のない store path 一覧
  */
  executionDependenciesFor =
    name:
    lib.unique (
      map (row: toString row.file.source) (
        builtins.filter (row: row.clientName == name && row.file.deployment != "seed") deploymentRows
      )
      ++ [ (toString runtimeContract.packages.gate) ]
      ++ lib.optional projectMemoryEnabled (toString cfg.capabilities.project-memory.runtime)
    );
  clientExecutionDependencies = lib.genAttrs clientNames executionDependenciesFor;
  # 公開 command は PATH の前に置く wrapper だけで、native profile の bin は PATH へ出さない
  publicCommand =
    name:
    let
      client = agents.clients.${name};
    in
    if modeOf client.runtime == "managed" then
      runtime.mkWrapper {
        client = name;
        inherit (client) binary;
        inherit (client.runtime.managed) argumentGuard;
        targetExecutable = clientExecutables.${name};
        executionDependencies = clientExecutionDependencies.${name};
      }
    else
      pkgs.writeShellApplication {
        name = client.binary;
        text = ''
          exec ${lib.escapeShellArg clientExecutables.${name}} "$@"
        '';
      };
  publicCommands = lib.listToAttrs (
    map (
      name:
      lib.nameValuePair "${runtimeWrapperDirectory}/${agents.clients.${name}.binary}" {
        source = lib.getExe (publicCommand name);
        executable = true;
      }
    ) clientNames
  );

  allSkillNames = builtins.attrNames cfg.skills.registry;
  rawSubagentSkillEdges = map (route: "${route.subagent}/${route.skill}") rawRouting.subagentSkills;
  rawSubagentHandoffEdges = map (
    route: "${route.from}/${route.to}/${route.artifact}"
  ) rawRouting.subagentHandoffs;
  unknownRawRoutingSubagents = lib.unique (
    map (route: route.subagent) (
      builtins.filter (
        route: !builtins.hasAttr route.subagent allSharedSubagents
      ) rawRouting.subagentSkills
    )
  );
  unknownRawRoutingSkills = lib.unique (
    map (route: route.skill) (
      builtins.filter (route: !builtins.elem route.skill allSkillNames) rawRouting.subagentSkills
    )
  );
  invalidRawRoutingActivations = lib.unique (
    map (route: route.activation) (
      builtins.filter (
        route:
        !(builtins.elem route.activation [
          "required"
          "dynamic"
        ])
      ) rawRouting.subagentSkills
    )
  );
  unknownRawHandoffEndpoints = lib.unique (
    lib.concatMap (
      route:
      lib.optional (!builtins.hasAttr route.from allSharedSubagents) route.from
      ++ lib.optional (!builtins.hasAttr route.to allSharedSubagents) route.to
    ) rawRouting.subagentHandoffs
  );
  duplicateRawSubagentSkillEdges =
    builtins.length rawSubagentSkillEdges != builtins.length (lib.unique rawSubagentSkillEdges);
  duplicateRawSubagentHandoffEdges =
    builtins.length rawSubagentHandoffEdges != builtins.length (lib.unique rawSubagentHandoffEdges);

  enabledSkillNames = cfg.skills.enabled;
  enabledSkills = lib.genAttrs enabledSkillNames (name: cfg.skills.registry.${name});
  discoverableSkills = lib.filterAttrs (_: skill: !isReferenceOnlySkill skill.source) enabledSkills;
  discoverableSkillNames = builtins.attrNames discoverableSkills;

  # 原版のまま採用した標準 Skill だけを原版を開く入口へ置き換える。差替えた source は原文のまま配り、registry は変えない
  standardSources = lib.mapAttrs (_: skill: skill.source) (
    lib.filterAttrs (
      name: skill: toString skill.source == "${pluginSources.architecture-standard}/skills/${name}"
    ) discoverableSkills
  );
  # 問い合わせ先は host が採用した flake.lock の original から導き、作業中の checkout や起動中の client から選ばない
  standardInput =
    flakeLock.nodes.${flakeLock.nodes.${flakeLock.root}.inputs.architectureStandard}.original;
  standardChecker = "${pluginSources.architecture-standard}/skills/standard-update/scripts/skill-package-check.sh";
  standardPackage = import ./impl/standard-package/package.nix {
    inherit lib pkgs;
    supervise = cfg.platform.supervise.package;
    reviewed = lib.mapAttrs (_: source: "${source}") standardSources;
    checker = standardChecker;
    origin = {
      inherit (standardInput) owner repo;
      ref = standardInput.ref or null;
    };
    stateRelative = lib.removePrefix "${cfg.workstation.homeDir}/" runtimeContract.state.root;
    nixPackage = config.nix.package;
    inherit (config.security.pki) caBundle;
  };
  # native 入口は同じホスト世代の resolver を指し、解決済みの原版は使われた公開版ごとに保持する
  standardRoutes = import ./impl/standard-package/routes.nix { inherit lib pkgs; } {
    sources = standardSources;
    command = standardPackage;
  };
  projectedSourceOf =
    name: skill:
    if builtins.hasAttr name standardSources then "${standardRoutes}/${name}" else skill.source;
  allSkills = lib.mapAttrs projectedSourceOf discoverableSkills;

  subagentsRoot = ./subagents;
  allSharedSubagents =
    lib.mapAttrs'
      (filename: _: lib.nameValuePair (lib.removeSuffix ".md" filename) (subagentsRoot + "/${filename}"))
      (
        lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".md" name) (
          builtins.readDir subagentsRoot
        )
      );
  unavailableRequiredSubagents = lib.unique (
    map (route: route.subagent) (
      builtins.filter (
        route: route.activation == "required" && !(builtins.elem route.skill discoverableSkillNames)
      ) rawRouting.subagentSkills
    )
  );
  eligibleSubagents = builtins.removeAttrs allSharedSubagents unavailableRequiredSubagents;
  routing = {
    subagentSkills = builtins.filter (
      route:
      builtins.hasAttr route.subagent eligibleSubagents
      && builtins.elem route.skill discoverableSkillNames
    ) rawRouting.subagentSkills;
    subagentHandoffs = builtins.filter (
      route: builtins.hasAttr route.from eligibleSubagents && builtins.hasAttr route.to eligibleSubagents
    ) rawRouting.subagentHandoffs;
  };
  renderSubagent =
    name: source:
    let
      routes = builtins.filter (route: route.subagent == name) routing.subagentSkills;
      handoffs = builtins.filter (route: route.from == name) routing.subagentHandoffs;
      routingLines =
        if routes == [ ] then
          "- なし"
        else
          lib.concatMapStringsSep "\n" (
            route: "- `${route.skill}`（${if route.activation == "required" then "必須" else "必要時"}）"
          ) routes;
      handoffLines =
        if handoffs == [ ] then
          "- なし"
        else
          lib.concatMapStringsSep "\n" (route: "- `${route.artifact}`を`${route.to}`へ渡す。") handoffs;
    in
    pkgs.replaceVars source {
      skillRouting = routingLines;
      handoffs = handoffLines;
    };
  sharedSubagents = lib.mapAttrs renderSubagent eligibleSubagents;

  policyInputs = {
    template = ./policy/AGENTS.md;
    constraints = ./policy/RULES.md;
    # 一覧の Source も native 入口と同じ投影を指し、原版 store への直接の経路を一覧から開かない
    skills = lib.mapAttrs (
      name: skill: skill // { source = projectedSourceOf name skill; }
    ) enabledSkills;
    subagents = sharedSubagents;
    capabilities = cfg.capabilities.resolved;
    inherit (agents) clients;
    inherit (cfg.workstation) dotfilesDir environmentDir;
  };
  policyRules = policy.render policyInputs;

  normalizeSource =
    source:
    if builtins.typeOf source == "path" then
      builtins.path {
        path = source;
        name = builtins.baseNameOf (toString source);
      }
    else
      source;

  # subagent は native と rendered だけが home へ配備され、declared は client の config が source を直接参照する
  sharedDeploymentRows = lib.concatMap (
    clientName:
    let
      client = agents.clients.${clientName};
      rulesDestination = rulesDestinationOf client;
      constraintsDestination = constraintsDestinationOf client;
      subagentDestination = subagentDestinationOf client;
      subagentSources = subagentSourcesOf client;
      clientPolicyRules =
        if
          subagentDestination != null
          && builtins.attrNames subagentSources != builtins.attrNames sharedSubagents
        then
          policy.render (policyInputs // { subagents = subagentSources; })
        else
          policyRules;
      subagentRows = lib.optionals (subagentDestination != null) (
        lib.mapAttrsToList (name: source: {
          inherit clientName;
          id = "subagents/${name}";
          file = {
            inherit source;
            format = "markdown";
            deployment = "home";
            destination = "${subagentDestination}/${name}.md";
          };
        }) subagentSources
      );
    in
    lib.optional (rulesDestination != null) {
      inherit clientName;
      id = "rules";
      file = {
        source = if constraintsDestination == null then clientPolicyRules else clientPolicyRules.core;
        format = "markdown";
        deployment = "home";
        destination = rulesDestination;
      };
    }
    ++ lib.optional (constraintsDestination != null) {
      inherit clientName;
      id = "constraints";
      file = {
        source = agents.shared.constraints;
        format = "markdown";
        deployment = "home";
        destination = constraintsDestination;
      };
    }
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
    ++ subagentRows
  ) clientNames;

  managedFileRows = lib.concatMap (
    clientName:
    lib.mapAttrsToList (id: file: {
      inherit clientName id file;
    }) agents.clients.${clientName}.managedFiles
  ) clientNames;

  normalizeRow =
    row:
    row
    // {
      file = row.file // {
        source = normalizeSource row.file.source;
      };
    };
  managedDeploymentRows = map normalizeRow managedFileRows;
  deploymentRows = map normalizeRow sharedDeploymentRows ++ managedDeploymentRows;

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
      target = "${cfg.workstation.homeDir}/${row.file.destination}";
    in
    ''
      target=${lib.escapeShellArg target}
      if [ ! -e "$target" ] && [ ! -L "$target" ]; then
        install -Dm600 ${lib.escapeShellArg (toString row.file.source)} "$target"
      fi
      ${lib.optionalString (row.file.seedMigrationCommand != null) ''
        ${lib.getExe row.file.seedMigrationCommand} "$target" ${lib.escapeShellArg cfg.workstation.homeDir} || exit $?
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
          deployedAt = "${cfg.workstation.homeDir}/${row.file.destination}";
        }
      )
    ) deploymentRows
  );

  homeDestinations = map (entry: entry.name) homeManagedEntries;
  seedDestinations = map (row: row.file.destination) seedRows;
  systemDestinations = map (entry: entry.name) systemManagedEntries;

  runtimeContract =
    let
      observationTimeoutSeconds = 10;
      relativeCacheRoot = ".cache/dotfiles-wsl";
      relativeStateRoot = ".local/state/dotfiles-wsl";
      commonObservation = checkId: resourceKey: failureMessage: {
        inherit checkId resourceKey failureMessage;
        timeoutSeconds = observationTimeoutSeconds;
      };
      timerObservation = timer: {
        kind = "systemd-timer";
        manager = "system";
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
      # profile の実体は /nix/store/<hash>-<package>-<version> にあるため、client process の識別は
      # store 名の glob で行う。profile を更新しても、更新前の世代で動き続ける process を外さない
      storeNameHash = lib.concatStrings (lib.replicate 32 "?");
      executableRootFor = client: "${builtins.storeDir}/${storeNameHash}-${client.supply.package}-*";
      clientObservation =
        name: client:
        commonObservation "agent/${name}" null
          "${client.binary} is unavailable or its version command failed"
        // {
          kind = "command-version";
          path = clientExecutables.${name};
          expectedSource = clientExecutables.${name};
          inherit (client) versionArgs;
        };
    in
    rec {
      cache = rec {
        inherit relativeCacheRoot;
        root = "${cfg.workstation.homeDir}/${relativeCacheRoot}";
        cargoBuildRoot = "${root}/cargo-build";
        sharedRoot = "${root}/shared";
        sessionsRoot = "${root}/sessions";
        verificationRoot = "${root}/verification";
        highBytes = 68719476736;
        lowBytes = 51539607552;
        inactiveDays = 30;
      };
      sliceUnit = "agents.slice";
      state = {
        root = "${cfg.workstation.homeDir}/${relativeStateRoot}";
      };
      timers = {
        autoupdate =
          if agents.automaticUpdates.clients == [ ] then
            null
          else
            {
              name = "dotfiles-agent-autoupdate";
              onCalendar = "daily";
              persistent = true;
            };
        projectCacheGc = {
          name = "dotfiles-agent-project-cache-gc";
          onCalendar = "daily";
          persistent = true;
        };
      };
      packages = {
        inherit (runtime)
          gate
          gc
          launcher
          verify
          ;
      };
      commands = {
        autoupdate = "${lib.getExe agentSupply} update --automatic";
        projectCacheGc = lib.getExe packages.gc;
      };
      observations = {
        "agents/roster" = commonObservation "agent-roster" null "agent roster is empty" // {
          kind = "roster";
          members = agents.enabled;
          minimumCount = 1;
          failureOnly = true;
        };
        "agents/maintenance/project-cache-gc" = timerObservation timers.projectCacheGc;
      }
      // lib.optionalAttrs (runtimeClientNames != [ ]) {
        "agents/slice-placement" =
          commonObservation "agent/slice-placement" "agentSlicePlacement"
            "agent client processes run outside ${sliceUnit}"
          // {
            kind = "process-slice";
            executableRoots = map (name: executableRootFor agents.clients.${name}) runtimeClientNames;
            slice = sliceUnit;
          };
      }
      // lib.optionalAttrs (timers.autoupdate != null) {
        "agents/maintenance/autoupdate" = timerObservation timers.autoupdate;
      }
      // lib.mapAttrs' (
        name: client: lib.nameValuePair "agents/client/${name}" (clientObservation name client)
      ) agents.clients;
    };
in
{
  imports = [
    ./clients/antigravity/module.nix
    ./clients/claude/module.nix
    ./clients/codex/module.nix
    ./clients/omp/module.nix
    ./clients/opencode/module.nix
    ./job/module.nix
    ./journal/module.nix
    ./memory-harvest/module.nix
    ./orca/module.nix
  ];

  options.dotfiles.agents = agentContract.options // {
    lifecycle = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      internal = true;
      description = "共通 runtime が供給する lifecycle の部品。`mkWrapper { client; binary; targetExecutable; executionDependencies; }` は共通の cache 方針を一度適用し、scope、管理 scratch、session の GC root を取ってから絶対 path の実行ファイルを起動する wrapper を作る。`protect` は `dotfiles-agent-protect [--resolved] ROOTS-DIRECTORY PATH...` で、profile の symlink を辿った先を含む store object へ GC root を取り、取れなければ非ゼロで終わる。`supervise` は子孫の終了を確認してから返す command。`--require-drained` を明示した呼び出しだけが、SIGKILL 後の猶予が過ぎても所有を手放さず ECHILD の確認まで返らない。";
    };
  };

  config = {
    dotfiles.agents = {
      clients = selectedClients;
      inherit clientExecutables clientExecutionDependencies;
      supply = {
        root = profileRoot;
        source = supplySource;
      };
      lifecycle = {
        inherit (runtime) mkWrapper protect supervise;
        wrapperDirectory = "${cfg.workstation.homeDir}/${runtimeWrapperDirectory}";
      };
      packages = {
        projectCacheGc = runtimeContract.packages.gc;
        verification = runtimeContract.packages.verify;
        verificationGate = runtimeContract.packages.gate;
      }
      // lib.optionalAttrs projectMemoryEnabled {
        projectMemoryHooks = config.dotfiles.capabilities.project-memory.clientIntegrations.hooks;
      }
      // lib.optionalAttrs (standardSources != { }) {
        inherit standardPackage;
      };
      runtime = {
        inherit (runtimeContract) timers state;
        cache = builtins.removeAttrs runtimeContract.cache [ "relativeCacheRoot" ];
      };
      shared = {
        rules = policyRules;
        rulesCore = policyRules.core;
        constraints = policyRules.constraintsFile;
        skills = allSkills;
        subagents = sharedSubagents;
        inherit routing;
      };
    };

    dotfiles.managedArtifacts = managedArtifacts;
    dotfiles.health.observations = runtimeContract.observations;
    dotfiles.platform.cli.commands = {
      inherit agentSupply toolSession;
    };

    assertions = [
      {
        assertion = unknownRawRoutingSubagents == [ ];
        message =
          "Subagent Skill routes reference unknown subagents: "
          + lib.concatStringsSep ", " unknownRawRoutingSubagents;
      }
      {
        assertion = unknownRawRoutingSkills == [ ];
        message =
          "Subagent Skill routes reference unknown Skills: "
          + lib.concatStringsSep ", " unknownRawRoutingSkills;
      }
      {
        assertion = invalidRawRoutingActivations == [ ];
        message =
          "Subagent Skill routes must use required or dynamic activation: "
          + lib.concatStringsSep ", " invalidRawRoutingActivations;
      }
      {
        assertion = !duplicateRawSubagentSkillEdges;
        message = "Subagent Skill routes must not contain duplicate edges";
      }
      {
        assertion = unknownRawHandoffEndpoints == [ ];
        message =
          "Subagent handoffs reference unknown subagents: "
          + lib.concatStringsSep ", " unknownRawHandoffEndpoints;
      }
      {
        assertion = !duplicateRawSubagentHandoffEdges;
        message = "Subagent handoffs must not contain duplicate edges";
      }
    ]
    ++ agentContract.assertionsFor agents
    ++ [
      {
        assertion = homeDestinations == lib.unique homeDestinations;
        message = "Agent home destinations must be unique";
      }
      {
        assertion = systemDestinations == lib.unique systemDestinations;
        message = "Agent system destinations must be unique";
      }
      {
        assertion =
          builtins.attrNames classSliceConfig == builtins.attrNames cfg.workstation.workload.classSlices;
        message = "Every workload class needs a slice declaration, and every class slice a class";
      }
      {
        assertion = lib.all (
          unit:
          let
            child = lib.removePrefix "${lib.removeSuffix ".slice" runtimeContract.sliceUnit}-" (
              lib.removeSuffix ".slice" unit
            );
          in
          lib.hasPrefix "${lib.removeSuffix ".slice" runtimeContract.sliceUnit}-" unit
          && !lib.hasInfix "-" child
        ) (builtins.attrValues cfg.workstation.workload.classSlices);
        message = "Workload class slices must be direct children of the agent slice so that its limits enclose them";
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
        assertion = agents.slice.memoryHighPercent < agents.slice.memoryMaxPercent;
        message = "Agent slice MemoryHigh must be below MemoryMax";
      }
      {
        assertion =
          agents.slice.memoryMaxPercent < agents.slice.userManager.memoryMaxPercent
          && agents.slice.userManager.memoryHighPercent < agents.slice.userManager.memoryMaxPercent;
        message = "User manager memory limits must enclose the agent slice and keep MemoryHigh below MemoryMax";
      }
      {
        assertion =
          map (timer: timer.name) (
            builtins.filter (timer: timer != null) (builtins.attrValues runtimeContract.timers)
          ) == lib.unique (
            map (timer: timer.name) (
              builtins.filter (timer: timer != null) (builtins.attrValues runtimeContract.timers)
            )
          );
        message = "Agent runtime timer names must be unique";
      }
    ]
    ++ lib.optionals (standardSources != { }) [
      {
        assertion =
          standardInput.type or null == "github"
          && !(standardInput ? rev)
          && lib.all (value: builtins.match "[A-Za-z0-9._-]+" value != null) [
            standardInput.owner
            standardInput.repo
          ]
          && (
            (standardInput.ref or "HEAD") == "HEAD"
            || builtins.match "refs/heads/[A-Za-z0-9._/-]+" standardInput.ref != null
          );
        message = "architectureStandard must follow a GitHub default branch or an explicit refs/heads/ branch, without rev";
      }
      {
        assertion = builtins.pathExists standardChecker;
        message = "the host-pinned architecture-standard has no package checker: ${standardChecker}";
      }
    ];

    environment.etc = lib.listToAttrs systemManagedEntries;
    environment.systemPackages = [
      config.dotfiles.agents.packages.projectCacheGc
      config.dotfiles.agents.packages.verification
      config.dotfiles.agents.packages.verificationGate
    ]
    ++ lib.optionals projectMemoryEnabled [
      config.dotfiles.agents.packages.projectMemoryHooks
    ]
    ++ lib.optionals (standardSources != { }) [
      config.dotfiles.agents.packages.standardPackage
    ];

    home-manager.users.${cfg.workstation.username} =
      { lib, ... }:
      {
        home.file = lib.mkMerge [
          (lib.listToAttrs homeManagedEntries)
          publicCommands
        ];
        home.sessionPath = lib.mkBefore [ "$HOME/${runtimeWrapperDirectory}" ];
        home.activation.seedAgentConfigs = lib.hm.dag.entryAfter [ "writeBoundary" ] seedScript;
        # 存在しない profile だけを locked baseline から作る。activation は latest を取得せず、
        # 既存 profile を baseline へ戻さない
        home.activation.initAgentSupply = lib.hm.dag.entryAfter [
          "writeBoundary"
          "seedAgentConfigs"
        ] "${lib.getExe agentSupply} init";
      };

    systemd.user.slices = {
      ${lib.removeSuffix ".slice" runtimeContract.sliceUnit} = {
        description = "Agent session の資源上限";
        sliceConfig = {
          MemoryHigh = "${toString agents.slice.memoryHighPercent}%";
          MemoryMax = "${toString agents.slice.memoryMaxPercent}%";
          MemorySwapMax = "${toString agents.slice.memorySwapMaxPercent}%";
          CPUWeight = agents.slice.cpuWeight;
        };
      };
    }
    // lib.mapAttrs' (
      class: unit:
      lib.nameValuePair (lib.removeSuffix ".slice" unit) {
        description = "検証の走行の scope を置く ${class} の slice";
        sliceConfig = classSliceConfig.${class};
      }
    ) cfg.workstation.workload.classSlices;

    # Chromium が自ら app.slice へ作る scope による agents.slice の迂回
    systemd.services."user@".serviceConfig = {
      MemoryHigh = "${toString agents.slice.userManager.memoryHighPercent}%";
      MemoryMax = "${toString agents.slice.userManager.memoryMaxPercent}%";
    };

    systemd.services.dotfiles-agent-autoupdate = lib.mkIf (runtimeContract.timers.autoupdate != null) {
      description = "Agent client を latest へ更新";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = cfg.workstation.username;
        Environment = [
          "HOME=${cfg.workstation.homeDir}"
          "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
        ];
        ExecStart = runtimeContract.commands.autoupdate;
      };
    };

    systemd.timers.dotfiles-agent-autoupdate = lib.mkIf (runtimeContract.timers.autoupdate != null) {
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
        User = cfg.workstation.username;
        Environment = "HOME=${cfg.workstation.homeDir}";
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
  };
}
