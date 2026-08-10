{ lib }:

let
  inherit (lib) types;
  nonEmpty = value: value != "";
  pathSegments = path: lib.splitString "/" path;
  validRelativeDestination =
    path:
    nonEmpty path
    && !lib.hasPrefix "/" path
    && builtins.all (segment: segment != "" && segment != "." && segment != "..") (pathSegments path);

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
        ];
      };
      deployment = lib.mkOption {
        type = types.enum [
          "system"
          "home"
          "seed"
        ];
      };
      destination = lib.mkOption { type = types.str; };
    };
  };

  installType = types.submodule {
    options = {
      kind = lib.mkOption {
        type = types.enum [
          "installer-script"
          "github-release"
        ];
      };
      scriptUrl = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      repo = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      assetByArch = lib.mkOption {
        type = types.nullOr (
          types.submodule {
            options = {
              x86_64 = lib.mkOption { type = types.str; };
              aarch64 = lib.mkOption { type = types.str; };
            };
          }
        );
        default = null;
      };
      binaryInArchive = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
      };
    };
  };

  clientType = types.submodule {
    options = {
      binary = lib.mkOption { type = types.str; };
      versionArgs = lib.mkOption {
        type = types.listOf types.str;
        default = [ "--version" ];
      };
      install = lib.mkOption { type = installType; };
      rulesDestination = lib.mkOption { type = types.str; };
      skillsDestination = lib.mkOption { type = types.str; };
      definitionMode = lib.mkOption {
        type = types.enum [
          "native"
          "rendered"
          "unsupported"
        ];
      };
      definitionsDestination = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      definitionFormat = lib.mkOption {
        type = types.nullOr (
          types.enum [
            "toml"
            "frontmatter-markdown"
          ]
        );
        default = null;
      };
      definitions = lib.mkOption {
        type = types.attrsOf types.path;
        default = { };
      };
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
            managedFile = lib.mkOption { type = types.str; };
          };
        };
      };
      managedFiles = lib.mkOption {
        type = types.attrsOf managedFileType;
        default = { };
      };
      capabilityManagedFiles = lib.mkOption {
        type = types.submodule {
          options = {
            lsp = lib.mkOption {
              type = types.nullOr types.str;
              default = null;
            };
            telemetry = lib.mkOption {
              type = types.nullOr types.str;
              default = null;
            };
            agentmemory = lib.mkOption {
              type = types.nullOr types.str;
              default = null;
            };
          };
        };
        default = { };
      };
      lspMode = lib.mkOption {
        type = types.enum [
          "supported"
          "unsupported"
        ];
      };
      telemetryMode = lib.mkOption {
        type = types.enum [
          "supported"
          "unsupported"
        ];
      };
      agentmemoryMode = lib.mkOption {
        type = types.enum [
          "hooks"
          "plugin"
          "unsupported"
        ];
      };
    };
  };

  definitionContractValid =
    client:
    if client.definitionMode == "native" then
      client.definitionsDestination != null
      && client.definitionFormat == null
      && client.definitions != { }
    else if client.definitionMode == "rendered" then
      client.definitionsDestination != null
      && client.definitionFormat != null
      && client.definitions != { }
    else
      client.definitionsDestination == null
      && client.definitionFormat == null
      && client.definitions == { };

  installContractValid =
    install:
    let
      present = value: value != null;
    in
    if install.kind == "installer-script" then
      present install.scriptUrl
      && install.repo == null
      && install.assetByArch == null
      && install.binaryInArchive == null
    else
      install.scriptUrl == null && present install.repo && present install.assetByArch;

  capabilityContractValid =
    client:
    let
      bindings = client.capabilityManagedFiles;
      referencedFiles = builtins.filter (file: file != null) (builtins.attrValues bindings);
    in
    ((client.lspMode == "supported") == (bindings.lsp != null))
    && ((client.telemetryMode == "supported") == (bindings.telemetry != null))
    && ((client.agentmemoryMode != "unsupported") == (bindings.agentmemory != null))
    && builtins.all (file: builtins.hasAttr file client.managedFiles) referencedFiles;

  # これらは command 名、argv、配備 path、生成 file 名、参照 key である。
  # 不在は null で表すため、意味を持たない空文字は受理しない。
  requiredStringFailuresFor =
    cfg:
    let
      clientNames = builtins.attrNames cfg.clients;
      invalidClientsFor =
        select: builtins.filter (name: !builtins.all nonEmpty (select cfg.clients.${name})) clientNames;
      clientsWhere = predicate: builtins.filter (name: predicate cfg.clients.${name}) clientNames;
      installClientsWhere = predicate: clientsWhere (client: predicate client.install);
      displayEmpty = value: if nonEmpty value then value else "<empty>";
    in
    {
      enabledIds = map displayEmpty (builtins.filter (id: !nonEmpty id) cfg.enabled);
      clientIds = map displayEmpty (builtins.filter (id: !nonEmpty id) clientNames);
      binaries = invalidClientsFor (client: [ client.binary ]);
      versionArguments = invalidClientsFor (client: client.versionArgs);
      rulesDestinations = invalidClientsFor (client: [ client.rulesDestination ]);
      skillsDestinations = invalidClientsFor (client: [ client.skillsDestination ]);
      definitionsDestinations = invalidClientsFor (
        client: lib.optional (client.definitionsDestination != null) client.definitionsDestination
      );
      definitionIds = invalidClientsFor (client: builtins.attrNames client.definitions);
      managedFileIds = invalidClientsFor (client: builtins.attrNames client.managedFiles);
      managedFileDestinations = invalidClientsFor (
        client: map (file: file.destination) (builtins.attrValues client.managedFiles)
      );
      gatewayManagedFileReferences = invalidClientsFor (client: [ client.gatewayConfig.managedFile ]);
      capabilityManagedFileReferences = invalidClientsFor (
        client: builtins.filter (value: value != null) (builtins.attrValues client.capabilityManagedFiles)
      );
      installScriptUrls = installClientsWhere (
        install:
        install.kind == "installer-script" && (install.scriptUrl == null || !nonEmpty install.scriptUrl)
      );
      installRepositories = installClientsWhere (
        install: install.kind == "github-release" && (install.repo == null || !nonEmpty install.repo)
      );
      installAssetsX86_64 = installClientsWhere (
        install:
        install.kind == "github-release"
        && (install.assetByArch == null || !nonEmpty install.assetByArch.x86_64)
      );
      installAssetsAarch64 = installClientsWhere (
        install:
        install.kind == "github-release"
        && (install.assetByArch == null || !nonEmpty install.assetByArch.aarch64)
      );
      installArchiveBinaries = installClientsWhere (
        install:
        install.kind == "github-release"
        && install.binaryInArchive != null
        && !nonEmpty install.binaryInArchive
      );
      sharedSkillIds = map displayEmpty (
        builtins.filter (id: !nonEmpty id) (builtins.attrNames cfg.shared.skills)
      );
      sharedDefinitionIds = map displayEmpty (
        builtins.filter (id: !nonEmpty id) (builtins.attrNames cfg.shared.definitions)
      );
    };

  requiredStringChecksFor =
    cfg: lib.mapAttrs (_: failures: failures == [ ]) (requiredStringFailuresFor cfg);
in
{
  inherit requiredStringChecksFor requiredStringFailuresFor;

  options = {
    enabled = lib.mkOption {
      type = types.listOf types.str;
      description = "この host が必要とする agent client ID。";
    };
    stateRoot = lib.mkOption {
      type = types.str;
      readOnly = true;
      internal = true;
      description = "agent が所有する session と linked worktree ledger の state root。";
    };
    agentResource = lib.mkOption {
      type = types.package;
      readOnly = true;
      internal = true;
      description = "agent session resource ledger と reaper の command package。";
    };
    agentWorktree = lib.mkOption {
      type = types.package;
      readOnly = true;
      internal = true;
      description = "linked worktree を生成して ownership ledger へ登録する command package。";
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
      definitions = lib.mkOption {
        type = types.attrsOf types.path;
        readOnly = true;
        internal = true;
      };
    };
    clients = lib.mkOption {
      type = types.attrsOf clientType;
      default = { };
      internal = true;
    };
  };

  assertionsFor =
    cfg:
    let
      clientNames = builtins.attrNames cfg.clients;
      invalidDefinitionClients = builtins.filter (
        name: !definitionContractValid cfg.clients.${name}
      ) clientNames;
      invalidInstallClients = builtins.filter (
        name: !installContractValid cfg.clients.${name}.install
      ) clientNames;
      sharedDestinationRows = lib.concatMap (
        clientName:
        let
          client = cfg.clients.${clientName};
        in
        [
          {
            inherit clientName;
            field = "rulesDestination";
            value = client.rulesDestination;
          }
          {
            inherit clientName;
            field = "skillsDestination";
            value = client.skillsDestination;
          }
        ]
        ++ lib.optional (client.definitionsDestination != null) {
          inherit clientName;
          field = "definitionsDestination";
          value = client.definitionsDestination;
        }
      ) clientNames;
      invalidSharedDestinationRows = builtins.filter (
        row: !validRelativeDestination row.value
      ) sharedDestinationRows;
      invalidSharedDestinationLabels = map (
        row: "${row.clientName}/${row.field} (${row.value})"
      ) invalidSharedDestinationRows;
      requiredStringFailures = lib.filterAttrs (_: failures: failures != [ ]) (
        requiredStringFailuresFor cfg
      );
      requiredStringFailureMessages = lib.mapAttrsToList (
        class: failures: "${class} (${lib.concatStringsSep ", " failures})"
      ) requiredStringFailures;
      missingGatewayManagedFiles = builtins.filter (
        name:
        !(builtins.hasAttr cfg.clients.${name}.gatewayConfig.managedFile cfg.clients.${name}.managedFiles)
      ) clientNames;
      invalidCapabilityClients = builtins.filter (
        name: !capabilityContractValid cfg.clients.${name}
      ) clientNames;
      managedRows = lib.concatMap (
        clientName:
        lib.mapAttrsToList (id: file: {
          inherit clientName id file;
        }) cfg.clients.${clientName}.managedFiles
      ) clientNames;
      invalidManagedDestinationRows = builtins.filter (
        row: !validRelativeDestination row.file.destination
      ) managedRows;
      invalidManagedDestinationLabels = map (
        row: "${row.clientName}/${row.id} (${row.file.deployment}: ${row.file.destination})"
      ) invalidManagedDestinationRows;
      # validator を通った destination 自体が canonical relative path である。
      userManagedDestinations = map (row: row.file.destination) (
        builtins.filter (row: row.file.deployment != "system") managedRows
      );
      systemManagedDestinations = map (row: row.file.destination) (
        builtins.filter (row: row.file.deployment == "system") managedRows
      );
      clientsWithoutVersionArgs = builtins.filter (
        name: cfg.clients.${name}.versionArgs == [ ]
      ) clientNames;
    in
    [
      {
        assertion = cfg.enabled != [ ] && cfg.enabled == lib.unique cfg.enabled;
        message = "dotfiles.agents.enabled must not be empty and must contain unique IDs";
      }
      {
        assertion = lib.sort builtins.lessThan cfg.enabled == lib.sort builtins.lessThan clientNames;
        message = "dotfiles.agents.enabled must exactly match the declared client keys";
      }
      {
        assertion = cfg.shared.skills != { };
        message = "dotfiles.agents.shared.skills must not be empty";
      }
      {
        assertion = cfg.shared.definitions != { };
        message = "dotfiles.agents.shared.definitions must not be empty";
      }
      {
        assertion = requiredStringFailures == { };
        message =
          "agent required semantic strings must be non-empty: "
          + lib.concatStringsSep "; " requiredStringFailureMessages;
      }
      {
        assertion = invalidDefinitionClients == [ ];
        message =
          "agent definition mode conflicts with destination, format, or sources: "
          + lib.concatStringsSep ", " invalidDefinitionClients;
      }
      {
        assertion = invalidInstallClients == [ ];
        message =
          "agent install kind conflicts with branch fields: "
          + lib.concatStringsSep ", " invalidInstallClients;
      }
      {
        assertion = invalidSharedDestinationRows == [ ];
        message =
          "agent shared destinations must be canonical home-relative paths: "
          + lib.concatStringsSep ", " invalidSharedDestinationLabels;
      }
      {
        assertion = invalidManagedDestinationRows == [ ];
        message =
          "agent managed destinations must be canonical deployment-relative paths: "
          + lib.concatStringsSep ", " invalidManagedDestinationLabels;
      }
      {
        assertion = missingGatewayManagedFiles == [ ];
        message =
          "agent gatewayConfig.managedFile must name a final managedFiles entry: "
          + lib.concatStringsSep ", " missingGatewayManagedFiles;
      }
      {
        assertion = invalidCapabilityClients == [ ];
        message =
          "agent capability mode conflicts with its final managed file binding: "
          + lib.concatStringsSep ", " invalidCapabilityClients;
      }
      {
        assertion = clientsWithoutVersionArgs == [ ];
        message =
          "agent versionArgs must not be empty: " + lib.concatStringsSep ", " clientsWithoutVersionArgs;
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
