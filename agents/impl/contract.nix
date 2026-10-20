{ lib }:

let
  inherit (lib) types;
  nonEmpty = value: value != "";
  validClientName =
    value:
    nonEmpty value && value != "." && value != ".." && builtins.match "[A-Za-z0-9._+-]+" value != null;
  # Linux NAME_MAX。binary 名は公開 wrapper の file 名になる
  clientBinaryMaxLength = 255;
  validClientBinaryName =
    value: validClientName value && builtins.stringLength value <= clientBinaryMaxLength;
  pathSegments = path: lib.splitString "/" path;
  validRelativeDestination =
    path:
    nonEmpty path
    && !lib.hasPrefix "/" path
    && builtins.all (segment: segment != "" && segment != "." && segment != "..") (pathSegments path);
  validAbsolutePath =
    path:
    path == "/"
    || (
      lib.hasPrefix "/" path
      && !lib.hasSuffix "/" path
      && builtins.all (segment: segment != "" && segment != "." && segment != "..") (
        lib.tail (pathSegments path)
      )
    );
  absolutePathType = types.addCheck types.str validAbsolutePath;
  relativeDestinationType = types.addCheck types.str validRelativeDestination;
  nonEmptyStringType = types.addCheck types.str nonEmpty;
  safeBasenameType = types.addCheck types.str validClientBinaryName;
  # llm-agents.nix の package attribute。flake 参照の一成分として引用なしで渡せる文字に限る
  supplyPackageType = types.addCheck types.str (
    value: builtins.match "[A-Za-z0-9][A-Za-z0-9._-]*" value != null
  );
  systemdUnitBasenameType = types.addCheck nonEmptyStringType (
    value:
    builtins.stringLength value <= 247 && builtins.match "[A-Za-z0-9][A-Za-z0-9_.-]*" value != null
  );
  systemdCalendarType = types.addCheck nonEmptyStringType (
    value: builtins.match "[^[:cntrl:]]*" value != null && builtins.match "[[:space:]]*" value == null
  );
  # attrsOf の key は型で表せないため、空 ID の拒否だけを key の検査として足す
  nonEmptyKeys = type: types.addCheck type (value: builtins.all nonEmpty (builtins.attrNames value));

  managedFileType = types.submodule {
    options = {
      source = lib.mkOption { type = types.path; };
      format = lib.mkOption {
        type = types.enum [
          "json"
          "toml"
          "yaml"
          "markdown"
          "text"
          "directory"
        ];
      };
      deployment = lib.mkOption {
        type = types.enum [
          "system"
          "home"
          "seed"
        ];
      };
      destination = lib.mkOption { type = relativeDestinationType; };
      seedMigrationCommand = lib.mkOption {
        type = types.nullOr types.package;
        default = null;
      };
    };
  };

  # 値を持たない枝。対応なしと、追加値のない対応形式を同じ表現にする
  emptyBranch = types.submodule { };
  # 対応形式が参照する最終 managedFiles の key。実在の照合は assertionsFor が構築時に行う
  managedFileBinding = types.submodule {
    options.managedFile = lib.mkOption { type = nonEmptyStringType; };
  };
  subagentSources = types.addCheck (nonEmptyKeys (types.attrsOf types.path)) (
    sources: sources != { }
  );

  branch = options: types.submodule { inherit options; };
  tag = type: lib.mkOption { inherit type; };

  subagentsType = types.attrTag {
    unsupported = tag emptyBranch;
    native = tag (branch {
      destination = lib.mkOption { type = relativeDestinationType; };
      sources = lib.mkOption { type = subagentSources; };
      skillProjection = lib.mkOption { type = types.enum [ "dynamic" ]; };
    });
    rendered = tag (branch {
      destination = lib.mkOption { type = relativeDestinationType; };
      sources = lib.mkOption { type = subagentSources; };
      skillProjection = lib.mkOption {
        type = types.enum [
          "preload"
          "dynamic"
        ];
      };
    });
    declared = tag (branch {
      sources = lib.mkOption { type = subagentSources; };
      skillProjection = lib.mkOption { type = types.enum [ "dynamic" ]; };
    });
  };

  rulesType = types.attrTag {
    file = tag (branch {
      destination = lib.mkOption { type = relativeDestinationType; };
    });
    embedded = tag emptyBranch;
  };

  runtimeType = types.attrTag {
    managed = tag emptyBranch;
    unsupported = tag emptyBranch;
  };

  supportType = types.attrTag {
    supported = tag managedFileBinding;
    unsupported = tag emptyBranch;
  };

  projectMemoryType = types.attrTag {
    hooks = tag managedFileBinding;
    plugin = tag managedFileBinding;
    unsupported = tag emptyBranch;
  };

  runtimeTimerType = types.submodule {
    options = {
      name = lib.mkOption { type = systemdUnitBasenameType; };
      onCalendar = lib.mkOption { type = systemdCalendarType; };
      persistent = lib.mkOption { type = types.bool; };
    };
  };

  subagentSkillRouteType = types.submodule {
    options = {
      subagent = lib.mkOption { type = nonEmptyStringType; };
      skill = lib.mkOption { type = nonEmptyStringType; };
      activation = lib.mkOption {
        type = types.enum [
          "required"
          "dynamic"
        ];
      };
    };
  };

  subagentHandoffType = types.submodule {
    options = {
      from = lib.mkOption { type = nonEmptyStringType; };
      to = lib.mkOption { type = nonEmptyStringType; };
      artifact = lib.mkOption { type = nonEmptyStringType; };
    };
  };

  routingType = types.submodule {
    options = {
      subagentSkills = lib.mkOption { type = types.listOf subagentSkillRouteType; };
      subagentHandoffs = lib.mkOption { type = types.listOf subagentHandoffType; };
    };
  };

  clientType = types.submodule {
    options = {
      binary = lib.mkOption { type = safeBasenameType; };
      supply = lib.mkOption {
        type = types.submodule {
          options.package = lib.mkOption {
            type = supplyPackageType;
            description = "供給元 flake の packages.<system> が公開する package attribute。binary は bin/<binary> に置かれる。";
          };
        };
        description = "client binary の供給契約。更新、rollback、世代の保持は dotfiles-agent-supply が client 別の native profile で行う。";
      };
      runtime = lib.mkOption {
        type = runtimeType;
        description = "agent runtime launcher wrapper の配備可否。unsupported は公開 command を runtime なしの直接起動にする。";
      };
      versionArgs = lib.mkOption {
        type = types.addCheck (types.listOf nonEmptyStringType) (args: args != [ ]);
        default = [ "--version" ];
      };
      rules = lib.mkOption { type = rulesType; };
      skillsDestination = lib.mkOption { type = relativeDestinationType; };
      subagents = lib.mkOption { type = subagentsType; };
      gatewayConfig = lib.mkOption {
        type = types.submodule {
          options = {
            source = lib.mkOption { type = types.path; };
            format = lib.mkOption {
              type = types.enum [
                "json"
                "toml"
              ];
            };
            managedFile = lib.mkOption { type = nonEmptyStringType; };
          };
        };
      };
      managedFiles = lib.mkOption {
        type = types.attrsOf managedFileType;
        default = { };
        # submodule 再構成時に制約が失われるため attrsOf submodule の addCheck は不採用
        apply =
          files:
          assert lib.assertMsg (builtins.all nonEmpty (
            builtins.attrNames files
          )) "agent managed file IDs must be non-empty";
          files;
      };
      lsp = lib.mkOption { type = supportType; };
      telemetry = lib.mkOption { type = supportType; };
      projectMemory = lib.mkOption { type = projectMemoryType; };
    };
  };

  modeOf = tagged: builtins.head (builtins.attrNames tagged);
  branchOf = tagged: tagged.${modeOf tagged};

  subagentSourcesOf = client: (branchOf client.subagents).sources or { };
  subagentDestinationOf = client: (branchOf client.subagents).destination or null;
  skillProjectionOf =
    client:
    if modeOf client.subagents == "unsupported" then
      "unsupported"
    else
      (branchOf client.subagents).skillProjection;
  rulesDestinationOf = client: client.rules.file.destination or null;
  capabilityFileOf = client: capability: (branchOf client.${capability}).managedFile or null;
in
{
  inherit
    modeOf
    branchOf
    subagentSourcesOf
    subagentDestinationOf
    skillProjectionOf
    rulesDestinationOf
    capabilityFileOf
    ;

  options = {
    enabled = lib.mkOption {
      type = types.listOf nonEmptyStringType;
      description = "この host が必要とする agent client ID。";
    };
    automaticUpdates.clients = lib.mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "自動更新する採用済み client ID。空なら手動更新のみ。";
    };
    packages = lib.mkOption {
      type = types.attrsOf types.package;
      readOnly = true;
      internal = true;
      description = "agent 固有の PATH package。";
    };
    clientExecutables = lib.mkOption {
      type = types.attrsOf absolutePathType;
      readOnly = true;
      internal = true;
      description = "採用済み agent client ID ごとの native profile 内の実行 path。PATH には置かず、公開 command は runtime wrapper か直接起動 wrapper が指す。";
    };
    clientExecutionDependencies = lib.mkOption {
      type = types.attrsOf (types.listOf absolutePathType);
      readOnly = true;
      internal = true;
      description = ''
        初回 seed 以外の配備 source を含む採用済み client ごとの不変な実行依存の store path 一覧
        session と timer job による全子の終了までの GC 保護
      '';
    };
    supply = {
      root = lib.mkOption {
        type = absolutePathType;
        readOnly = true;
        internal = true;
        description = "client 別 native profile の親 directory。";
      };
      source = lib.mkOption {
        type = nonEmptyStringType;
        readOnly = true;
        internal = true;
        description = "更新時に最新 revision を解決する供給元の flake reference。flake.lock の採用 input から導く。";
      };
    };
    runtime = {
      skillRoots = lib.mkOption {
        type = types.listOf relativeDestinationType;
        readOnly = true;
        internal = true;
      };
      cache = lib.mkOption {
        type = types.submodule {
          options = {
            root = lib.mkOption { type = absolutePathType; };
            cargoBuildRoot = lib.mkOption { type = absolutePathType; };
            sharedRoot = lib.mkOption { type = absolutePathType; };
            sessionsRoot = lib.mkOption { type = absolutePathType; };
            verificationRoot = lib.mkOption { type = absolutePathType; };
            highBytes = lib.mkOption { type = types.ints.positive; };
            lowBytes = lib.mkOption { type = types.ints.positive; };
            inactiveDays = lib.mkOption { type = types.ints.positive; };
          };
        };
        readOnly = true;
        internal = true;
      };
      state = lib.mkOption {
        type = types.submodule {
          options = {
            root = lib.mkOption { type = absolutePathType; };
          };
        };
        readOnly = true;
        internal = true;
      };
      timers = lib.mkOption {
        type = types.submodule {
          options = {
            autoupdate = lib.mkOption { type = types.nullOr runtimeTimerType; };
            projectCacheGc = lib.mkOption { type = runtimeTimerType; };
          };
        };
        readOnly = true;
        internal = true;
      };
    };
    slice = {
      memoryHighPercent = lib.mkOption {
        type = types.ints.between 1 99;
        default = 60;
        description = "agents.sliceのMemoryHighを物理RAMの百分率で指定する。";
      };
      memoryMaxPercent = lib.mkOption {
        type = types.ints.between 1 99;
        default = 70;
        description = "agents.sliceのMemoryMaxを物理RAMの百分率で指定する。";
      };
      memorySwapMaxPercent = lib.mkOption {
        type = types.ints.between 0 100;
        default = 20;
        description = "agents.sliceのMemorySwapMaxを物理RAMの百分率で指定する。";
      };
      cpuWeight = lib.mkOption {
        type = types.ints.between 1 10000;
        default = 50;
        description = "agents.slice の CPUWeight。同じ user manager の他の slice の既定 100 より低くする。";
      };
      userManager = {
        memoryHighPercent = lib.mkOption {
          type = types.ints.between 1 99;
          default = 67;
          description = "user manager全体のMemoryHighを物理RAMの百分率で指定する。";
        };
        memoryMaxPercent = lib.mkOption {
          type = types.ints.between 1 99;
          default = 75;
          description = "user manager全体のMemoryMaxを物理RAMの百分率で指定する。";
        };
      };
    };
    shared = {
      rules = lib.mkOption {
        type = types.path;
        readOnly = true;
        internal = true;
      };
      skills = lib.mkOption {
        type = types.attrsOf types.path;
        readOnly = true;
        internal = true;
      };
      subagents = lib.mkOption {
        type = types.attrsOf types.path;
        readOnly = true;
        internal = true;
      };
      routing = lib.mkOption {
        type = routingType;
        readOnly = true;
        internal = true;
      };
    };
    registry = lib.mkOption {
      type = types.attrsOf clientType;
      default = { };
      description = "選択可能な agent client adapter。登録だけでは配備しない。";
    };
    clients = lib.mkOption {
      type = types.attrsOf clientType;
      readOnly = true;
      internal = true;
      description = "enabled が選んだ client adapter。";
    };
  };

  # 型が表せない枝間の整合だけを構築時に拒否する。枝の形と必須値、path の形は型が拒否する
  assertionsFor =
    cfg:
    let
      clientNames = builtins.attrNames cfg.clients;
      unknownEnabledClients = builtins.filter (name: !(builtins.hasAttr name cfg.registry)) cfg.enabled;
      invalidClientNames = builtins.filter (name: !validClientName name) (
        builtins.attrNames cfg.registry
      );
      emptySharedIds = builtins.filter (id: !nonEmpty id) (
        builtins.attrNames cfg.shared.skills ++ builtins.attrNames cfg.shared.subagents
      );
      bindingRows = lib.concatMap (
        clientName:
        let
          client = cfg.clients.${clientName};
          capabilityRows =
            lib.concatMap
              (
                capability:
                let
                  file = capabilityFileOf client capability;
                in
                lib.optional (file != null) {
                  inherit clientName file;
                  field = capability;
                }
              )
              [
                "lsp"
                "telemetry"
                "projectMemory"
              ];
        in
        [
          {
            inherit clientName;
            field = "gatewayConfig";
            file = client.gatewayConfig.managedFile;
          }
        ]
        ++ capabilityRows
      ) clientNames;
      danglingBindingLabels = map (row: "${row.clientName}/${row.field} (${row.file})") (
        builtins.filter (
          row: !(builtins.hasAttr row.file cfg.clients.${row.clientName}.managedFiles)
        ) bindingRows
      );
      managedRows = lib.concatMap (
        clientName:
        lib.mapAttrsToList (id: file: {
          inherit clientName id file;
        }) cfg.clients.${clientName}.managedFiles
      ) clientNames;
      invalidSeedMigrationLabels = map (row: "${row.clientName}/${row.id}") (
        builtins.filter (
          row: row.file.seedMigrationCommand != null && row.file.deployment != "seed"
        ) managedRows
      );
      userManagedDestinations = map (row: row.file.destination) (
        builtins.filter (row: row.file.deployment != "system") managedRows
      );
      systemManagedDestinations = map (row: row.file.destination) (
        builtins.filter (row: row.file.deployment == "system") managedRows
      );
      clientBinaries = map (name: cfg.clients.${name}.binary) clientNames;
      supplyPackages = map (name: cfg.clients.${name}.supply.package) clientNames;
    in
    [
      {
        assertion = cfg.enabled != [ ] && cfg.enabled == lib.unique cfg.enabled;
        message = "dotfiles.agents.enabled must not be empty and must contain unique IDs";
      }
      {
        assertion = invalidClientNames == [ ];
        message =
          "agent client IDs must be safe basenames: " + lib.concatStringsSep ", " invalidClientNames;
      }
      {
        assertion = unknownEnabledClients == [ ];
        message =
          "dotfiles.agents.enabled references unavailable adapters: "
          + lib.concatStringsSep ", " unknownEnabledClients;
      }
      {
        assertion =
          cfg.automaticUpdates.clients == lib.unique cfg.automaticUpdates.clients
          && builtins.all (name: builtins.elem name cfg.enabled) cfg.automaticUpdates.clients;
        message = "dotfiles.agents.automaticUpdates.clients must contain unique enabled client IDs";
      }
      {
        assertion = cfg.shared.skills != { };
        message = "dotfiles.agents.shared.skills must not be empty";
      }
      {
        assertion = cfg.shared.subagents != { };
        message = "dotfiles.agents.shared.subagents must not be empty";
      }
      {
        assertion = emptySharedIds == [ ];
        message = "agent shared Skill and subagent IDs must be non-empty";
      }
      {
        assertion = danglingBindingLabels == [ ];
        message =
          "agent gateway and capability bindings must name a final managedFiles entry: "
          + lib.concatStringsSep ", " danglingBindingLabels;
      }
      {
        assertion = invalidSeedMigrationLabels == [ ];
        message =
          "agent seedMigrationCommand is only valid for seed deployment: "
          + lib.concatStringsSep ", " invalidSeedMigrationLabels;
      }
      {
        assertion = clientBinaries == lib.unique clientBinaries;
        message = "agent client binaries must be unique";
      }
      {
        assertion = supplyPackages == lib.unique supplyPackages;
        message = "agent client supply packages must be unique";
      }
      {
        assertion = userManagedDestinations == lib.unique userManagedDestinations;
        message = "agent home and seed managed file destinations must be unique";
      }
      {
        assertion = systemManagedDestinations == lib.unique systemManagedDestinations;
        message = "agent system managed file destinations must be unique";
      }
    ];
}
