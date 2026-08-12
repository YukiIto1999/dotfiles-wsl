{
  helpers,
  pkgs,
  lib,
  self,
  hostConfig,
  hostOptions,
  mkNixosSystem,
  normalMachineModule,
  units,
  allCheckNames,
  variantConfig,
  ...
}:

let
  # 根 unit の名前。data 用の directory は unit ではないので対象にしない
  rootUnitNames = lib.unique (
    builtins.filter (name: name != "") (map (unit: lib.head (lib.splitString "/" unit.id)) units)
  );

  expectedRootOptionOwners = [
    "accounts"
    "agents"
    "artifacts"
    "commands"
    "containers"
    "gates"
    "host"
    "mcp"
    "observations"
    "telemetry"
    "toolchain"
  ];
  expectedRootUnitNames = expectedRootOptionOwners ++ [ "sops" ];
  rootUnit =
    name:
    lib.findSingle (
      unit: unit.id == name
    ) (throw "missing unit: ${name}") (throw "duplicate unit: ${name}") units;
  containersUnit = rootUnit "containers";
  mcpUnit = rootUnit "mcp";
  machineInputProjection = cfg: {
    inherit (cfg.dotfiles) accounts;
    agents = cfg.dotfiles.agents.enabled;
    containers = cfg.dotfiles.containers.enabled;
    enabledLsp = cfg.dotfiles.toolchain.enabledLsp;
    enabledProviders = cfg.dotfiles.mcp.enabledProviders;
    workIdentity = cfg.dotfiles.toolchain.git.workIdentity;
  };

  # 全 consumer の移行後は例外を持たない。空集合も下の AST scan が実入力を
  # 検出したことを確かめるため、gate 自体は vacuous にならない。
  allowedPureHelperImports = { };

  commandHelper = ".." + "/commands/impl/mk-command.nix";
  nestedCommandHelper = ".." + "/.." + "/commands/impl/mk-command.nix";
  userSecretHelper = ".." + "/sops/impl/user-secret-file.nix";
  approvedExplicitHelperImports = {
    "accounts/module.nix" = {
      target = userSecretHelper;
      line = "  mkUserSecretFile = import ${userSecretHelper} { inherit username; };";
    };
    "agents/module.nix" = {
      target = commandHelper;
      line = "  mkCommand = import ${commandHelper} { inherit config lib pkgs; };";
    };
    "containers/module.nix" = {
      target = commandHelper;
      line = "  mkCommand = import ${commandHelper} { inherit config lib pkgs; };";
    };
    "containers/sonarqube/module.nix" = {
      target = nestedCommandHelper;
      line = "  mkCommand = import ${nestedCommandHelper} { inherit config lib pkgs; };";
    };
  };

  forbiddenOwnership = [
    "mcp/memory/package/engine"
    "mcp/memory/assets/engine-config.yaml"
    "mcp/searxng/assets/settings.yml"
  ];

  # path を式で組み立てる file reader は境界を文字列検索から隠せる。
  # 現在必要な動的 operand の source と件数を固定し、追加は明示的な変更にする
  allowedDynamicImports = {
    "flake.nix" = 1;
  };
  allowedDynamicFileReads = {
    "accounts/checks.nix" = 1;
    "accounts/module.nix" = 3;
    "agents/codex/module.nix" = 1;
    "agents/opencode/module.nix" = 1;
    "commands/impl/mk-command.nix" = 1;
    "containers/searxng/module.nix" = 1;
    "gates/impl/exec-tokens.nix" = 1;
  };

  homeConfig = hostConfig.home-manager.users.${hostConfig.dotfiles.host.username};
  pathOwnerPackages = lib.unique (
    builtins.attrValues hostConfig.dotfiles.toolchain.packages
    ++ builtins.attrValues hostConfig.dotfiles.agents.packages
    ++ map (server: server.package) (builtins.attrValues hostConfig.dotfiles.toolchain.lsp)
    ++ builtins.attrValues hostConfig.dotfiles.commands
  );
  pathPackages = lib.unique (
    pathOwnerPackages ++ homeConfig.home.packages ++ hostConfig.environment.systemPackages
  );

  wslviewPackage =
    lib.findSingle (package: lib.getName package == "wslview") (throw "wslview package is missing")
      (throw "multiple wslview packages are installed")
      hostConfig.environment.systemPackages;
  commandSmokeTimeoutArgs = [
    "--kill-after=2s"
    "10s"
  ];
  generatedShellActual = {
    agentmemoryHooks = toString hostConfig.dotfiles.agents.agentmemory.hooks;
    commands = lib.mapAttrs (_: package: lib.getExe package) hostConfig.dotfiles.commands;
    commandSmoke.timeoutArgs = commandSmokeTimeoutArgs;
    mcpFronts = lib.mapAttrs (
      _: front: hostConfig.systemd.services.${front.service}.serviceConfig.ExecStart
    ) hostConfig.dotfiles.mcp.fronts;
    host.wslview = lib.getExe wslviewPackage;
  };
in
{
  structure-responsibility-roots =
    let
      expectedSonarqubeUnits = [
        "containers/sonarqube"
        "mcp/sonarqube"
      ];
      actualSonarqubeUnits = lib.sort builtins.lessThan (
        map (unit: unit.id) (builtins.filter (unit: builtins.baseNameOf unit.path == "sonarqube") units)
      );
      legacyPath = "toolchain/" + "sonarqube";
      legacyPathExists = builtins.pathExists (self + "/${legacyPath}");
      expectedRootEntries = [
        ".editorconfig"
        ".envrc"
        ".github"
        ".gitignore"
        "CONTRIBUTING.md"
        "LICENSE"
        "README.md"
        "accounts"
        "agents"
        "artifacts"
        "commands"
        "containers"
        "docs"
        "flake.lock"
        "flake.nix"
        "gates"
        "host"
        "mcp"
        "observations"
        "sops"
        "statix.toml"
        "telemetry"
        "toolchain"
      ];
      rootEntriesMatch = entries: builtins.attrNames entries == expectedRootEntries;
      rootEntries = builtins.readDir self;
      responsibilityViolations =
        lib.optional (builtins.pathExists (self + "/secrets")) "root-secrets"
        ++ lib.optional (lib.hasAttrByPath [
          "dotfiles"
          "containers"
          "agentmemory"
          "clients"
        ] hostConfig) "containers-agentmemory-clients"
        ++ lib.optional (hostConfig.dotfiles.toolchain.packages ? apm) "toolchain-apm"
        ++ lib.optional (
          !lib.hasAttrByPath [
            "dotfiles"
            "agents"
            "agentmemory"
            "hooks"
          ] hostConfig
        ) "missing-agents-agentmemory"
        ++ lib.optional (
          !lib.hasAttrByPath [
            "dotfiles"
            "agents"
            "packages"
            "apm"
          ] hostConfig
        ) "missing-agents-apm";
      legacyAgentMemoryOptions = lib.hasAttrByPath [
        "dotfiles"
        "containers"
        "agentmemory"
        "clients"
      ] hostOptions;
    in
    assert lib.assertMsg (
      actualSonarqubeUnits == expectedSonarqubeUnits && !legacyPathExists
    ) "${legacyPath} must be split into containers/sonarqube and mcp/sonarqube";
    assert lib.assertMsg (rootEntriesMatch rootEntries) (
      "flake source root entries differ from the responsibility roster: actual="
      + builtins.toJSON (builtins.attrNames rootEntries)
    );
    assert !(rootEntriesMatch (rootEntries // { unexpected = "directory"; }));
    assert !legacyAgentMemoryOptions;
    assert lib.assertMsg (
      machineInputProjection variantConfig == machineInputProjection hostConfig
    ) "the gateway variant must preserve the normal machine inputs outside the gateway port";
    assert lib.assertMsg (responsibilityViolations == [ ]) (
      "responsibility roots are not separated by role: "
      + lib.concatStringsSep " " responsibilityViolations
    );
    pkgs.runCommandLocal "check-structure-responsibility-roots"
      { nativeBuildInputs = [ pkgs.ripgrep ]; }
      ''
        set -euo pipefail

        reverse_dependency_pattern='dotfiles\.agents|(\.\./)+agents(/|"|$)|\$\{self\}/agents|self[[:space:]]*\+[[:space:]]*"/agents'
        if rg -n --glob '*.nix' "$reverse_dependency_pattern" ${containersUnit.path}; then
          echo "container backend depends on the agent integration owner" >&2
          exit 1
        fi
        for application in ${lib.escapeShellArgs hostConfig.dotfiles.containers.enabled}; do
          if rg -n -F "$application" ${containersUnit.path}/module.nix; then
            echo "generic container module knows an application id: $application" >&2
            exit 1
          fi
        done
        for provider in ${lib.escapeShellArgs hostConfig.dotfiles.mcp.enabledProviders}; do
          if rg -n -F "$provider" ${mcpUnit.path}/module.nix; then
            echo "generic MCP module knows a provider id: $provider" >&2
            exit 1
          fi
        done
        if rg -n -F 'mcp-front-' ${containersUnit.path} --glob 'module.nix' --glob 'checks.nix'; then
          echo "container owner knows an MCP front unit" >&2
          exit 1
        fi
        while IFS= read -r mutation; do
          printf '%s\n' "$mutation" | rg -q "$reverse_dependency_pattern"
        done < ${./fixtures/container-agent-reverse-dependencies.txt}
        touch $out
      '';

  # 同じ実行ファイル名を二人が持つと、どちらが効くかは PATH の順序で決まる
  toolchain-single-owner =
    assert lib.all (
      package:
      lib.elem package homeConfig.home.packages || lib.elem package hostConfig.environment.systemPackages
    ) pathOwnerPackages;
    pkgs.runCommandLocal "check-toolchain-single-owner"
      {
        nativeBuildInputs = [ pkgs.coreutils ];
        roots = pathPackages;
        ownedRoots = pathOwnerPackages;
      }
      ''
        set -euo pipefail

        for root in $roots; do
          [ -d "$root/bin" ] || continue
          for entry in "$root"/bin/*; do
            printf '%s\t%s\n' "$(basename "$entry")" "$root"
          done
        done | sort -u > owners

        for root in $ownedRoots; do
          [ -d "$root/bin" ] || continue
          for entry in "$root"/bin/*; do
            basename "$entry"
          done
        done | sort -u > owned-names

        cut -f1 owners | uniq -d | sort -u > duplicates
        comm -12 duplicates owned-names > conflicts
        if [ -s conflicts ]; then
          echo "an executable this repository declares is also provided by another package:" >&2
          grep -F -f conflicts owners >&2
          exit 1
        fi
        touch $out
      '';

  unit-module-marker =
    let
      unitTree = import ./fixtures/unit-tree.nix;
      fixtureCollectUnits = import ./impl/collect-units.nix {
        inherit lib;
        inherit (unitTree) readDir;
      };
      fixtureActual = map (unit: unit.id) (fixtureCollectUnits unitTree.root);
    in
    assert lib.assertMsg (fixtureActual == unitTree.expectedIds) (
      "unit collector fixture mismatch: actual=${builtins.toJSON fixtureActual} "
      + "expected=${builtins.toJSON unitTree.expectedIds}"
    );
    pkgs.runCommandLocal "check-unit-module-marker"
      {
        nativeBuildInputs = [
          pkgs.diffutils
          pkgs.findutils
        ];
      }
      ''
        set -euo pipefail

        printf '%s\n' ${lib.escapeShellArgs (map (unit: unit.id) units)} | sort > actual
        find ${self} -type f -name module.nix -printf '%h\n' \
          | while IFS= read -r directory; do
            printf '%s\n' "''${directory#${self}/}"
          done \
          | sort > expected

        diff -u expected actual
        touch $out
      '';

  structure-unit-directory-names =
    let
      fixture = import ./fixtures/structure-unit-directory-names.nix;
      segmentIsValid = segment: builtins.match "[a-z][a-z0-9]*(-[a-z0-9]+)*" segment != null;
      unitIdIsValid = id: lib.all segmentIsValid (lib.splitString "/" id);
      invalidUnitIds = map (unit: unit.id) (builtins.filter (unit: !unitIdIsValid unit.id) units);
    in
    assert lib.all segmentIsValid fixture.valid;
    assert lib.all (segment: !segmentIsValid segment) fixture.invalid;
    assert lib.all (segment: !unitIdIsValid "root/${segment}") fixture.invalid;
    assert lib.all (segment: !unitIdIsValid "${segment}/leaf") fixture.invalid;
    assert lib.all (segment: !unitIdIsValid "root/${segment}/leaf") fixture.invalid;
    assert lib.assertMsg (invalidUnitIds == [ ]) (
      "unit directory names must use lowercase kebab-case: " + lib.concatStringsSep " " invalidUnitIds
    );
    pkgs.runCommandLocal "check-structure-unit-directory-names" { } "touch $out";

  runtime-identity =
    let
      expected = builtins.fromJSON (builtins.readFile ./fixtures/runtime-identities.json);
      containers = hostConfig.virtualisation.oci-containers.containers;
      containerValues = builtins.attrValues containers;
      gatewayEndpoint = hostConfig.dotfiles.mcp.gateway;

      containerNetworks = lib.unique (
        lib.sort builtins.lessThan (
          map (lib.removePrefix "--network=") (
            lib.concatMap (
              container: builtins.filter (lib.hasPrefix "--network=") container.extraOptions
            ) containerValues
          )
        )
      );

      agentmemoryPersistentMounts = builtins.filter (
        volume:
        let
          segments = lib.splitString ":" volume;
        in
        builtins.length segments >= 2
        && lib.hasPrefix "/var/lib/" (lib.head segments)
        && builtins.elemAt segments 1 == "/data"
      ) containers.agentmemory.volumes;

      actual =
        assert lib.assertMsg (
          builtins.length containerNetworks == 1
        ) "runtime identity requires one container network: actual=${builtins.toJSON containerNetworks}";
        assert lib.assertMsg (builtins.length agentmemoryPersistentMounts == 1)
          "runtime identity requires one agentmemory persistent mount: actual=${builtins.toJSON agentmemoryPersistentMounts}";
        {
          mcpTargets = lib.mapAttrs (_: target: target.port) hostConfig.dotfiles.mcp.targets;
          gateway = {
            inherit (gatewayEndpoint) id port service;
          };
          containers = lib.sort builtins.lessThan (builtins.attrNames containers);
          containerNetwork = lib.head containerNetworks;
          secrets = lib.sort builtins.lessThan (builtins.attrNames hostConfig.sops.secrets);
          agentmemoryPersistentMount = lib.head agentmemoryPersistentMounts;
        };
      identityMatches = candidate: candidate == expected;
      missingTargetMutation = actual // {
        mcpTargets = builtins.removeAttrs actual.mcpTargets [ "memory" ];
      };
      commandNames = builtins.attrNames hostConfig.dotfiles.commands;
      serviceNames = builtins.attrNames hostConfig.systemd.services;
      timerNames = builtins.attrNames hostConfig.systemd.timers;
      installerExecutable = builtins.baseNameOf (lib.getExe hostConfig.dotfiles.commands.installAgents);
      legacyInstallerKey = "install" + "Clis";
      updaterName = "dotfiles-agent-autoupdate";
      legacyUpdaterName = "dotfiles-" + "cli-autoupdate";
      updaterNamesValid =
        services: timers:
        builtins.elem updaterName services
        && builtins.elem updaterName timers
        && !builtins.elem legacyUpdaterName services
        && !builtins.elem legacyUpdaterName timers;
    in
    assert lib.assertMsg (identityMatches actual) (
      "runtime identity mismatch: expected=${builtins.toJSON expected} "
      + "actual=${builtins.toJSON actual}"
    );
    assert lib.assertMsg (
      !identityMatches missingTargetMutation
    ) "runtime identity fixture accepted a deleted MCP target";
    assert installerExecutable == "dotfiles-install-agents";
    assert builtins.elem "installAgents" commandNames;
    assert !builtins.elem legacyInstallerKey commandNames;
    assert updaterNamesValid serviceNames timerNames;
    assert updaterNamesValid serviceNames (builtins.filter (timer: timer == updaterName) timerNames);
    assert !updaterNamesValid serviceNames (builtins.filter (timer: timer != updaterName) timerNames);
    pkgs.runCommandLocal "check-runtime-identity" { } "touch $out";

  # 全登録簿に共通する保険。各 owner の check も、自分が検査する集合の非空を
  # 独立して要求する
  registries-non-empty =
    let
      walk =
        path: opts:
        lib.concatLists (
          lib.mapAttrsToList (
            name: value:
            let
              here = path ++ [ name ];
            in
            if !(lib.isAttrs value) then
              [ ]
            else if value ? _type && value._type == "option" then
              lib.optional (
                lib.hasPrefix "attribute set of" (value.type.description or "")
                && lib.attrByPath here { } hostConfig == { }
              ) (lib.concatStringsSep "." here)
            else
              walk here value
          ) opts
        );

      empty = walk [ "dotfiles" ] hostOptions.dotfiles;
      unexpectedEmpty = builtins.filter (path: path != "dotfiles.observations") empty;
    in
    assert unexpectedEmpty == [ ];
    pkgs.runCommandLocal "check-registries-non-empty" { } "touch $out";

  # unit の層の file 名。ここが唯一の定義で、検査はここを読む
  # loopback port の占有は host 全体の資源で、単一 unit の不変条件ではない。
  # 宣言を増やさず、既存の contract と container 宣言から全 listener を集める
  # port を宣言しない生 unit は他のどの check にも届かない。socat 一本で
  # gateway と同じ port を 0.0.0.0 で取れる。unit を登録制にする
  service-listener-registry =
    let
      mcp = hostConfig.dotfiles.mcp;
      telemetry = hostConfig.dotfiles.telemetry;

      declaredHere = lib.unique (
        lib.concatMap (
          definition:
          lib.optionals (lib.hasPrefix (toString self) (toString definition.file)) (
            builtins.attrNames definition.value
          )
        ) hostOptions.systemd.services.definitionsWithLocations
      );

      # port を持たないと宣言した unit。増えるときは必ずこの表に現れる
      withoutListener = [
        "dotfiles-agent-autoupdate"
        "dotfiles-agent-project-cache-gc"
        "dotfiles-agent-resource-reaper"
        "dotfiles-zram-swap"
        "docker-buildkit-gc"
        "docker-dotfiles-backends-network"
        "fstrim"
        "nix-daemon"
        "sonarqube-provision"
      ];

      registered = lib.sort builtins.lessThan (
        lib.unique (
          map (front: front.service) (builtins.attrValues mcp.fronts)
          ++ [ mcp.gateway.service ]
          ++ [ telemetry.service ]
          ++ map (name: "docker-${name}") (
            builtins.attrNames hostConfig.virtualisation.oci-containers.containers
          )
          ++ withoutListener
        )
      );
    in
    assert lib.assertMsg (lib.sort builtins.lessThan declaredHere == registered) (
      "systemd service is not registered as a listener or as portless: "
      + lib.concatStringsSep " " (
        lib.subtractLists registered declaredHere ++ lib.subtractLists declaredHere registered
      )
    );
    pkgs.runCommandLocal "check-service-listener-registry" { } "touch $out";

  loopback-port-single-owner =
    let
      mcp = hostConfig.dotfiles.mcp;
      telemetry = hostConfig.dotfiles.telemetry;
      inherit (helpers.containerArgv)
        publishedPorts
        ;

      listeners =
        lib.mapAttrsToList (name: front: {
          owner = "mcp-front-${name}";
          inherit (front) port;
        }) mcp.fronts
        ++ [
          {
            owner = mcp.gateway.service;
            inherit (mcp.gateway) port;
          }
          {
            owner = mcp.gateway.service;
            port = 15000;
          }
          {
            owner = mcp.gateway.service;
            port = 15020;
          }
          {
            owner = mcp.gateway.service;
            port = 15021;
          }
        ]
        ++ lib.mapAttrsToList (_: port: {
          owner = telemetry.service;
          inherit port;
        }) telemetry.ports
        ++ map (entry: {
          inherit (entry) owner;
          port = lib.toInt (builtins.elemAt (lib.splitString ":" entry.value) 1);
        }) publishedPorts;

      # owner を unique にしてから数えると、同じ owner が同じ port を二度
      # bind する形を見逃す。listener の数で判定する
      listenersOn = port: lib.filter (listener: listener.port == port) listeners;
      numbers = lib.unique (map (listener: listener.port) listeners);
      duplicates = lib.filter (port: builtins.length (listenersOn port) > 1) numbers;
    in
    assert listeners != [ ];
    assert lib.assertMsg (duplicates == [ ]) (
      "loopback port is bound by more than one owner: "
      + lib.concatMapStringsSep ", " (
        port:
        "${toString port} <- "
        + lib.concatStringsSep " " (map (listener: listener.owner) (listenersOn port))
      ) duplicates
    );
    pkgs.runCommandLocal "check-loopback-port-single-owner" { } "touch $out";

  # option の root は宣言した repository root unit と一致させる。
  # 正規表現ではなく module system が持つ宣言位置から判定する。
  option-namespace =
    let
      rootOf =
        declaration:
        let
          segments = lib.splitString "/" (lib.removePrefix "${self}/" (toString declaration));
        in
        if segments == [ ] then "" else lib.head segments;

      repositoryDeclarations =
        declarations:
        builtins.filter (declaration: lib.hasPrefix "${self}/" (toString declaration)) declarations;

      repositoryDefinitions =
        definitions:
        builtins.filter (definition: lib.hasPrefix "${self}/" (toString definition.file)) definitions;

      sharedRegistryPaths = [
        # artifacts unit が型付き extension point を所有し、consumer unit が entry を登録する。
        [
          "dotfiles"
          "artifacts"
        ]
        # commands unit が型付き extension point を所有し、consumer unit が entry を登録する。
        [
          "dotfiles"
          "commands"
        ]
        # observations unit が型付き extension point を所有し、各 owner unit が entry を登録する。
        [
          "dotfiles"
          "observations"
        ]
      ];

      # module system の全 option leaf を辿る。dotfiles 配下だけを起点にすると、
      # repository が別 root を追加した場合に検査対象から外れてしまう。
      optionLeavesFor =
        options:
        let
          walk =
            path: current:
            lib.concatLists (
              lib.mapAttrsToList (
                name: option:
                let
                  here = path ++ [ name ];
                in
                if !(lib.isAttrs option) || name == "_module" then
                  [ ]
                else if option ? _type && option._type == "option" then
                  [
                    {
                      inherit here;
                      declarations = repositoryDeclarations (option.declarations or [ ]);
                    }
                  ]
                else
                  walk here option
              ) current
            );
        in
        walk [ ] options;

      repositoryOptionsFor =
        options: builtins.filter (entry: entry.declarations != [ ]) (optionLeavesFor options);

      declarationViolationsFor =
        options:
        let
          repositoryOptions = repositoryOptionsFor options;
          outsideDotfiles = builtins.filter (
            entry: entry.here == [ ] || lib.head entry.here != "dotfiles"
          ) repositoryOptions;
          wrongOwner = builtins.filter (
            entry:
            entry.here != [ ]
            && lib.head entry.here == "dotfiles"
            && (
              builtins.length entry.here < 2
              || !lib.all (declaration: rootOf declaration == builtins.elemAt entry.here 1) entry.declarations
            )
          ) repositoryOptions;
        in
        outsideDotfiles ++ wrongOwner;

      definitionLeavesFor =
        options:
        let
          walk =
            path: current:
            lib.concatLists (
              lib.mapAttrsToList (
                name: option:
                let
                  here = path ++ [ name ];
                in
                if !(lib.isAttrs option) || name == "_module" then
                  [ ]
                else if option ? _type && option._type == "option" then
                  [
                    {
                      inherit here;
                      definitions = repositoryDefinitions (option.definitionsWithLocations or [ ]);
                    }
                  ]
                else
                  walk here option
              ) current
            );
        in
        walk [ "dotfiles" ] options.dotfiles;

      definitionViolationsFor =
        options:
        builtins.filter (
          entry:
          builtins.length entry.definitions > 0
          && !builtins.elem entry.here sharedRegistryPaths
          && (!lib.all (definition: rootOf definition.file == builtins.elemAt entry.here 1) entry.definitions)
        ) (definitionLeavesFor options);

      describe =
        entry:
        "${lib.concatStringsSep "." entry.here} <- ${lib.concatStringsSep "," (map rootOf entry.declarations)}";
      describeDefinition =
        entry:
        "${lib.concatStringsSep "." entry.here} <- "
        + lib.concatStringsSep "," (map (definition: rootOf definition.file) entry.definitions);
      repositoryOptions = repositoryOptionsFor hostOptions;
      actualRootOptionOwners = lib.sort builtins.lessThan (
        lib.unique (lib.concatMap (entry: map rootOf entry.declarations) repositoryOptions)
      );
      missingRootModuleDeclarations = builtins.filter (
        owner:
        !lib.any (
          entry:
          builtins.length entry.here >= 2
          && builtins.elemAt entry.here 0 == "dotfiles"
          && builtins.elemAt entry.here 1 == owner
          && builtins.elem "${self}/${owner}/module.nix" (map toString entry.declarations)
        ) repositoryOptions
      ) expectedRootOptionOwners;

      fixtureOptions =
        file: optionPath:
        (lib.evalModules {
          modules = [
            {
              _file = "${self}/${file}";
              options = lib.setAttrByPath optionPath (lib.mkOption { type = lib.types.str; });
            }
          ];
        }).options;
      correctFixture = fixtureOptions "agents/module.nix" [
        "dotfiles"
        "agents"
        "fixture"
      ];
      wrongOwnerFixture = fixtureOptions "agents/module.nix" [
        "dotfiles"
        "containers"
        "fixture"
      ];
      rogueRootFixture = fixtureOptions "agents/module.nix" [
        "rogue"
        "fixture"
      ];
      definitionFixture =
        args:
        import ./fixtures/option-namespace-definition-ownership.nix (
          {
            inherit lib self;
          }
          // args
        );
      correctDefinitionFixture = definitionFixture {
        definitionFile = "agents/codex/module.nix";
      };
      wrongDefinitionFixture = definitionFixture {
        definitionFile = "mcp/context7/module.nix";
      };
      wrongRegistryDefinitionFixture = definitionFixture {
        declarationFile = "mcp/module.nix";
        definitionFile = "agents/module.nix";
        optionPath = [
          "dotfiles"
          "mcp"
          "targets"
        ];
        optionType = lib.types.attrsOf lib.types.str;
        definitionValue.fixture = "fixture";
      };
      declarationViolations = map describe (declarationViolationsFor hostOptions);
      definitionViolations = map describeDefinition (definitionViolationsFor hostOptions);
    in
    assert lib.sort builtins.lessThan rootUnitNames == lib.sort builtins.lessThan expectedRootUnitNames;
    assert actualRootOptionOwners == expectedRootOptionOwners;
    assert missingRootModuleDeclarations == [ ];
    assert declarationViolationsFor correctFixture == [ ];
    assert declarationViolationsFor wrongOwnerFixture != [ ];
    assert declarationViolationsFor rogueRootFixture != [ ];
    assert definitionViolationsFor correctDefinitionFixture == [ ];
    assert definitionViolationsFor wrongDefinitionFixture != [ ];
    assert definitionViolationsFor wrongRegistryDefinitionFixture != [ ];
    assert lib.assertMsg (declarationViolations == [ ]) (
      "option declaration namespace: " + lib.concatStringsSep " " declarationViolations
    );
    assert lib.assertMsg (definitionViolations == [ ]) (
      "option definition namespace: " + lib.concatStringsSep " " definitionViolations
    );
    pkgs.runCommandLocal "check-option-namespace" { } "touch $out";

  dotfiles-option-namespace =
    pkgs.runCommandLocal "check-dotfiles-option-namespace"
      {
        nativeBuildInputs = [ pkgs.ripgrep ];
      }
      ''
        set -euo pipefail

        legacyOptionPrefix='m'
        legacyOptionPrefix+='y\.'
        globalArgumentPath='config\._module'
        globalArgumentPath+='\.args'
        injectedHelperArguments='\b(mkCommand|mkContainerBackend|mkMcpServer|serveOverProxy|seedConfig|mkUserSecretFile),'
        violations=$(rg -n --glob '*.nix' \
          "(^|[^A-Za-z0-9_])$legacyOptionPrefix|$globalArgumentPath|$injectedHelperArguments" \
          ${self} || true)
        if [ -n "$violations" ]; then
          printf '%s\n' "$violations" >&2
          exit 1
        fi

        touch $out
      '';

  required-roster-negative-eval =
    let
      requiredRosterOptionPaths = [
        [
          "dotfiles"
          "accounts"
        ]
        [
          "dotfiles"
          "agents"
          "enabled"
        ]
        [
          "dotfiles"
          "containers"
          "enabled"
        ]
        [
          "dotfiles"
          "mcp"
          "enabledProviders"
        ]
        [
          "dotfiles"
          "toolchain"
          "enabledLsp"
        ]
      ];
      rosterOptionsWithDefaults = builtins.filter (
        path: (lib.attrByPath path { } hostOptions) ? default
      ) requiredRosterOptionPaths;
      fixtures = [
        ./fixtures/invalid/missing-rosters.nix
        ./fixtures/invalid/unknown-account.nix
        ./fixtures/invalid/unknown-agent.nix
        ./fixtures/invalid/unknown-container.nix
        ./fixtures/invalid/unknown-lsp.nix
        ./fixtures/invalid/unknown-provider.nix
      ];
      fixtureCases = map (fixture: {
        name = toString fixture;
        module = fixture;
      }) fixtures;
      isolatedRosterCases = [
        {
          name = "empty-account-roster";
          module = { lib, ... }: {
            dotfiles.accounts = lib.mkForce [ ];
          };
        }
        {
          name = "missing-account";
          module = { lib, ... }: {
            dotfiles.accounts = lib.mkForce [
              "account-1"
              "account-2"
            ];
          };
        }
        {
          name = "empty-agent-roster";
          module = { lib, ... }: {
            dotfiles.agents.enabled = lib.mkForce [ ];
          };
        }
        {
          name = "missing-agent";
          module = { lib, ... }: {
            dotfiles.agents.enabled = lib.mkForce [
              "antigravity"
              "claude"
              "codex"
            ];
          };
        }
        {
          name = "empty-container-roster";
          module = { lib, ... }: {
            dotfiles.containers.enabled = lib.mkForce [ ];
          };
        }
        {
          name = "missing-container";
          module = { lib, ... }: {
            dotfiles.containers.enabled = lib.mkForce [
              "agentmemory"
              "crawl4ai"
              "searxng"
            ];
          };
        }
        {
          name = "empty-provider-roster";
          module = { lib, ... }: {
            dotfiles.mcp.enabledProviders = lib.mkForce [ ];
          };
        }
        {
          name = "missing-provider";
          module = { lib, ... }: {
            dotfiles.mcp.enabledProviders = lib.mkForce [
              "chrome-devtools"
              "codex"
              "context7"
              "crawl4ai"
              "github"
              "memory"
              "playwright"
              "searxng"
            ];
          };
        }
        {
          name = "empty-lsp-roster";
          module = { lib, ... }: {
            dotfiles.toolchain.enabledLsp = lib.mkForce [ ];
          };
        }
        {
          name = "missing-lsp";
          module = { lib, ... }: {
            dotfiles.toolchain.enabledLsp = lib.mkForce [
              "bash"
              "csharp"
              "java"
              "nix"
              "python"
              "rust"
            ];
          };
        }
      ];
      invalidCases = fixtureCases ++ isolatedRosterCases;
      forceToplevel = systemConfig: builtins.deepSeq systemConfig.system.build.toplevel.drvPath true;
      negativeResults = map (invalidCase: {
        inherit (invalidCase) name;
        result = builtins.tryEval (
          forceToplevel
            (mkNixosSystem [
              normalMachineModule
              invalidCase.module
            ]).config
        );
      }) invalidCases;
      unexpectedSuccesses = map (entry: entry.name) (
        builtins.filter (entry: entry.result.success) negativeResults
      );
      normalResult = builtins.tryEval (forceToplevel hostConfig);
      variantResult = builtins.tryEval (forceToplevel variantConfig);
    in
    assert lib.assertMsg (rosterOptionsWithDefaults == [ ]) (
      "required roster options must not define defaults: "
      + lib.concatStringsSep " " (map (lib.concatStringsSep ".") rosterOptionsWithDefaults)
    );
    assert lib.assertMsg normalResult.success "normal required roster evaluation must succeed";
    assert lib.assertMsg variantResult.success "variant required roster evaluation must succeed";
    assert lib.assertMsg (unexpectedSuccesses == [ ]) (
      "invalid required roster evaluation succeeded: " + lib.concatStringsSep " " unexpectedSuccesses
    );
    pkgs.runCommandLocal "check-required-roster-negative-eval" { } "touch $out";

  # unit をまたぐ依存は型付き option と allowlist に固定した pure helper の
  # exact import だけを通す。他 unit の impl や assets を広く読むと、
  # 宣言していない結合になる
  unit-boundary-name-only =
    assert lib.assertMsg (
      allowedPureHelperImports == { }
    ) "container backend helper allowlist must remain empty";
    pkgs.runCommandLocal "check-unit-boundary-name-only"
      {
        nativeBuildInputs = [
          pkgs.ast-grep
          pkgs.gnugrep
          pkgs.jq
        ];
      }
      ''
        set -euo pipefail

        # 層の名前を数え上げると module.nix や checks.nix への直接参照が漏れる。
        # 根 unit の名前を宣言集合として持ち、そこへ入る path を全部拒む
        roots=${lib.escapeShellArg (lib.concatStringsSep " " rootUnitNames)}
        # container owner は ../impl で local helper を読む。root 外からの旧 path
        # だけを target にすると、allowlist が空になった後の scan が vacuous になる。
        backendSuffix=impl/container-backend.nix
        workDir=$PWD

        # comment や string の断片ではなく、reader と operand を Nix AST から取る。
        # operand が path literal でなければ、source ごとの許可件数と照合する
        (
          cd ${self}
          ast-grep run --lang nix --json=compact -p '$F $P' . --globs '*.nix' > "$workDir/applications.json"
          ast-grep run --lang nix --json=compact -p 'let $A = $V; in {}' \
            --selector binding . --globs '*.nix' > "$workDir/bindings.json"
        )
        jq '[
          .[]
          | select((.metaVariables.single.F.text | gsub("[[:space:]()]"; "")) == "import")
        ]' "$workDir/applications.json" > "$workDir/imports.json"
        jq '[
          .[]
          | select((.metaVariables.single.F.text | gsub("[[:space:]()]"; "")) == "builtins.readFile")
        ]' "$workDir/applications.json" > "$workDir/read-files.json"
        jq --slurpfile bindings "$workDir/bindings.json" --arg suffix "$backendSuffix" '
          def compact: gsub("[[:space:]()+\\\"]"; "");
          def identifier: test("^[A-Za-z_][A-Za-z0-9_\\u0027-]*$");
          def resolves_target($file; $expression; $seen):
            ($expression | compact) as $value
            | if ($value | contains($suffix)) then true
              elif (($expression | identifier) and (($seen | index($expression)) == null)) then
                any($bindings[0][];
                  .file == $file
                  and .metaVariables.single.A.text == $expression
                  and resolves_target(
                    $file;
                    .metaVariables.single.V.text;
                    $seen + [ $expression ]
                  ))
              else false
              end;
          [
            .[]
            | select(resolves_target(.file; .metaVariables.single.P.text; []))
          ]
        ' "$workDir/imports.json" > "$workDir/target-imports.json"
        jq --slurpfile bindings "$workDir/bindings.json" --arg suffix "$backendSuffix" '
          def compact: gsub("[[:space:]()+\\\"]"; "");
          def identifier: test("^[A-Za-z_][A-Za-z0-9_\\u0027-]*$");
          def resolves_target($file; $expression; $seen):
            ($expression | compact) as $value
            | if ($value | contains($suffix)) then true
              elif (($expression | identifier) and (($seen | index($expression)) == null)) then
                any($bindings[0][];
                  .file == $file
                  and .metaVariables.single.A.text == $expression
                  and resolves_target(
                    $file;
                    .metaVariables.single.V.text;
                    $seen + [ $expression ]
                  ))
              else false
              end;
          [
            .[]
            | select(resolves_target(.file; .metaVariables.single.P.text; []))
          ]
        ' "$workDir/read-files.json" > "$workDir/target-read-files.json"

        readerAliasCount=$(jq '[
          .[]
          | .metaVariables.single.V.text
          | gsub("[[:space:]()]"; "")
          | select(. == "import" or . == "builtins.readFile")
        ] | length' "$workDir/bindings.json")
        targetImportTotal=$(jq 'length' "$workDir/target-imports.json")

        violations=""
        if [ "$targetImportTotal" -eq 0 ]; then
          violations="$violations container-backend-import-scan-is-empty"
        fi
        if [ "$readerAliasCount" -ne 0 ]; then
          violations="$violations reader-alias-binding=$readerAliasCount"
        fi
        for allowed in ${lib.escapeShellArgs (builtins.attrNames allowedPureHelperImports)}; do
          [ -f "${self}/$allowed" ] || violations="$violations missing-allowlisted-source:$allowed"
        done
        for approved in ${lib.escapeShellArgs (builtins.attrNames approvedExplicitHelperImports)}; do
          [ -f "${self}/$approved" ] || violations="$violations missing-approved-helper-consumer:$approved"
        done

        while IFS= read -r file; do
          relative=''${file#${self}/}
          owner=''${relative%%/*}
          allowedTarget=""
          expectedImport=""
          approvedTarget=""
          approvedImport=""
          expectedDynamicImports=0
          expectedDynamicFileReads=0
          case "$relative" in
            ${lib.concatStringsSep "\n" (
              lib.mapAttrsToList (source: target: ''
                ${lib.escapeShellArg source})
                  allowedTarget=${lib.escapeShellArg target}
                  expectedImport=${lib.escapeShellArg "  mkContainerBackend = import ${target} { inherit lib; };"}
                  ;;
              '') allowedPureHelperImports
            )}
          esac

          case "$relative" in
            ${lib.concatStringsSep "\n" (
              lib.mapAttrsToList (source: spec: ''
                ${lib.escapeShellArg source})
                  approvedTarget=${lib.escapeShellArg spec.target}
                  approvedImport=${lib.escapeShellArg spec.line}
                  ;;
              '') approvedExplicitHelperImports
            )}
          esac

          case "$relative" in
            ${lib.concatStringsSep "\n" (
              lib.mapAttrsToList (source: count: ''
                ${lib.escapeShellArg source}) expectedDynamicImports=${toString count} ;;
              '') allowedDynamicImports
            )}
          esac
          case "$relative" in
            ${lib.concatStringsSep "\n" (
              lib.mapAttrsToList (source: count: ''
                ${lib.escapeShellArg source}) expectedDynamicFileReads=${toString count} ;;
              '') allowedDynamicFileReads
            )}
          esac

          source=$(cat "$file")
          dynamicImportCount=$(jq --arg file "$relative" '[
            .[]
            | select(.file == $file)
            | select(.metaVariables.single.P.text | test("^\\.{1,2}/") | not)
          ] | length' "$workDir/imports.json")
          dynamicFileReadCount=$(jq --arg file "$relative" '[
            .[]
            | select(.file == $file)
            | select(.metaVariables.single.P.text | test("^\\.{1,2}/") | not)
          ] | length' "$workDir/read-files.json")
          targetImportCount=$(jq --arg file "$relative" '[
            .[] | select(.file == $file)
          ] | length' "$workDir/target-imports.json")
          targetFileReadCount=$(jq --arg file "$relative" '[
            .[] | select(.file == $file)
          ] | length' "$workDir/target-read-files.json")
          targetApplicationCount=$(jq --arg file "$relative" --arg suffix "$backendSuffix" '[
            .[]
            # この check の script 自体が target suffix を検査値として持つ
            | select(.file == $file and .file != "gates/checks.nix")
            | .metaVariables.single.P.text
            | gsub("[[:space:]()+\\\"]"; "")
            | select(contains($suffix))
          ] | length' "$workDir/applications.json")

          if [ -n "$approvedTarget" ]; then
            approvedImportCount=$(printf '%s\n' "$source" | grep -Fxc -- "$approvedImport" || true)
            approvedTargetCount=$(printf '%s\n' "$source" | grep -Fo -- "$approvedTarget" | wc -l || true)
            approvedImportNodeCount=$(jq \
              --arg file "$relative" \
              --arg target "$approvedTarget" \
              '[
                .[]
                | select(.file == $file)
                | select((.metaVariables.single.P.text | gsub("[[:space:]()]"; "")) == $target)
              ] | length' "$workDir/imports.json")
            if [ "$approvedImportCount" -ne 1 ] \
              || [ "$approvedTargetCount" -ne 1 ] \
              || [ "$approvedImportNodeCount" -ne 1 ]; then
              violations="$violations $relative:approved-helper-import=$approvedImportCount,target-reference=$approvedTargetCount,import-node=$approvedImportNodeCount"
            else
              source=''${source/"$approvedTarget"/}
            fi
          fi

          if [ "$dynamicImportCount" -ne "$expectedDynamicImports" ] \
            || [ "$dynamicFileReadCount" -ne "$expectedDynamicFileReads" ]; then
            violations="$violations $relative:dynamic-import=$dynamicImportCount/$expectedDynamicImports,dynamic-read-file=$dynamicFileReadCount/$expectedDynamicFileReads"
          fi

          if [ -n "$allowedTarget" ]; then
            importCount=$(printf '%s\n' "$source" | grep -Fxc -- "$expectedImport" || true)
            targetCount=$(printf '%s\n' "$source" | grep -Fo -- "$allowedTarget" | wc -l || true)
            if [ "$importCount" -ne 1 ] || [ "$targetCount" -ne 1 ] \
              || [ "$targetImportCount" -ne 1 ] || [ "$targetFileReadCount" -ne 0 ] \
              || [ "$targetApplicationCount" -ne 1 ]; then
              violations="$violations $relative:exact-helper-import=$importCount,target-reference=$targetCount,target-import-node=$targetImportCount,target-read-file-node=$targetFileReadCount,target-application-node=$targetApplicationCount"
            else
              # 件数を先に一つへ固定しているため、許可した target だけを一度除ける
              source=''${source/"$allowedTarget"/}
            fi
          elif [ "$owner" != "containers" ] \
            && { [ "$targetImportCount" -ne 0 ] || [ "$targetFileReadCount" -ne 0 ] \
              || [ "$targetApplicationCount" -ne 0 ]; }; then
            violations="$violations $relative:target-import-node=$targetImportCount,target-read-file-node=$targetFileReadCount,target-application-node=$targetApplicationCount"
          fi

          while IFS= read -r target; do
            target=''${target%%/*}
            [ "$target" = "$owner" ] && continue
            for root in $roots; do
              [ "$target" = "$root" ] || continue
              violations="$violations ''${file#${self}/}->$target"
            done
          done < <(
            printf '%s\n' "$source" \
              | grep -ohE 'self \+ "/[a-z0-9-]+/|\$\{self\}/[a-z0-9-]+/|\.\./[a-z0-9-]+/' \
              | sed -E 's|^self \+ "/||; s|^\$\{self\}/||; s|^\.\./||' || true
          )
        done < <(find ${self} -name '*.nix' -not -path '*/.git/*')

        if [ -n "$violations" ]; then
          echo "unit reads another unit through a path instead of a contract:$violations" >&2
          exit 1
        fi
        touch $out
      '';

  # MCP unit は backend contract の consumer。OCI 配備、secret template、同名
  # backend の secret と service contract を持つと ownership が再び混ざる
  mcp-no-container-ownership =
    let
      ownershipFixture = import ./fixtures/mcp-container-ownership.nix;
      mcpContainerOwnership = import ./impl/mcp-container-ownership.nix { inherit lib; };
      ownersWith =
        resolveUnitOwner: fixtureUnits:
        map (
          case:
          let
            owner = resolveUnitOwner fixtureUnits case.file;
          in
          if owner == null then null else owner.id
        ) ownershipFixture.ownerCases;
      # 列挙順に依存する誤実装を逆順 fixture で落とすための mutation。
      lastMatchUnitOwner =
        fixtureUnits: relativeFile:
        lib.foldl' (
          owner: unit:
          if relativeFile == unit.id || lib.hasPrefix "${unit.id}/" relativeFile then unit else owner
        ) null fixtureUnits;
      fixtureOwners = ownersWith mcpContainerOwnership.resolveUnitOwner ownershipFixture.scan.units;
      lastMatchFixtureOwners = ownersWith lastMatchUnitOwner ownershipFixture.scan.units;
      reverseFixtureOwners = ownersWith mcpContainerOwnership.resolveUnitOwner (
        lib.reverseList ownershipFixture.scan.units
      );
      lastMatchReverseOwners = ownersWith lastMatchUnitOwner (
        lib.reverseList ownershipFixture.scan.units
      );
      expectedFixtureOwners = map (case: case.expected) ownershipFixture.ownerCases;
      fixtureScan = mcpContainerOwnership.scan ownershipFixture.scan;
      emptyFixtureScan = mcpContainerOwnership.scan ownershipFixture.emptyScan;
      unresolvedFixtureScan = mcpContainerOwnership.scan ownershipFixture.unresolvedScan;
      combinedFixtureScan = mcpContainerOwnership.scan ownershipFixture.combinedScan;

      relativeFile = file: lib.removePrefix "${self}/" (toString file);
      relativeDefinitions =
        definitions:
        map (definition: {
          file = relativeFile definition.file;
          inherit (definition) value;
        }) definitions;
      actualScan = mcpContainerOwnership.scan {
        inherit units;
        definitions = {
          ociContainers = relativeDefinitions hostOptions.virtualisation.oci-containers.containers.definitionsWithLocations;
          templates = relativeDefinitions hostOptions.sops.templates.definitionsWithLocations;
          services = relativeDefinitions hostOptions.dotfiles.containers.services.definitionsWithLocations;
          secrets = relativeDefinitions hostOptions.sops.secrets.definitionsWithLocations;
        };
      };

    in
    assert lib.assertMsg (fixtureOwners == expectedFixtureOwners) (
      "MCP ownership resolver fixture mismatch: actual=${builtins.toJSON fixtureOwners} "
      + "expected=${builtins.toJSON expectedFixtureOwners}"
    );
    assert lib.assertMsg (reverseFixtureOwners == expectedFixtureOwners) (
      "MCP ownership resolver reverse fixture mismatch: actual=${builtins.toJSON reverseFixtureOwners} "
      + "expected=${builtins.toJSON expectedFixtureOwners}"
    );
    assert lib.assertMsg (lastMatchFixtureOwners == expectedFixtureOwners) (
      "last-match mutation no longer reproduces the previous passing fixture: "
      + "actual=${builtins.toJSON lastMatchFixtureOwners} "
      + "expected=${builtins.toJSON expectedFixtureOwners}"
    );
    assert lib.assertMsg (
      lastMatchReverseOwners != expectedFixtureOwners
    ) "MCP ownership resolver fixture does not reject a last-match mutation";
    assert lib.assertMsg (fixtureScan == ownershipFixture.expectedScan) (
      "MCP ownership detector fixture mismatch: actual=${builtins.toJSON fixtureScan} "
      + "expected=${builtins.toJSON ownershipFixture.expectedScan}"
    );
    assert lib.assertMsg (emptyFixtureScan == ownershipFixture.expectedEmptyScan) (
      "empty MCP ownership scan fixture mismatch: actual=${builtins.toJSON emptyFixtureScan} "
      + "expected=${builtins.toJSON ownershipFixture.expectedEmptyScan}"
    );
    assert lib.assertMsg (unresolvedFixtureScan == ownershipFixture.expectedUnresolvedScan) (
      "unresolved MCP ownership scan fixture mismatch: "
      + "actual=${builtins.toJSON unresolvedFixtureScan} "
      + "expected=${builtins.toJSON ownershipFixture.expectedUnresolvedScan}"
    );
    assert lib.assertMsg (combinedFixtureScan == ownershipFixture.expectedCombinedScan) (
      "combined MCP ownership scan fixture mismatch: actual=${builtins.toJSON combinedFixtureScan} "
      + "expected=${builtins.toJSON ownershipFixture.expectedCombinedScan}"
    );
    pkgs.runCommandLocal "check-mcp-no-container-ownership"
      {
        inherit (actualScan) diagnosticText;
      }
      ''
        set -euo pipefail

        if [ -n "$diagnosticText" ]; then
          printf '%s\n' "$diagnosticText" >&2
          exit 1
        fi
        touch $out
      '';

  structure-layer-names =
    let
      materialNames = [
        "module.nix"
        "package.nix"
        "checks.nix"
        "impl"
        "assets"
        "fixtures"
        "checks"
        "package"
        "shared"
      ];
      entryIsValid =
        name: kind: hasChildModule:
        (builtins.elem name materialNames && (name != "checks" || kind == "directory"))
        || (kind == "directory" && hasChildModule);
      fixture = import ./fixtures/structure-layer-names.nix;
      fixtureIsValid = entry: entryIsValid entry.name entry.kind entry.hasChildModule;
      invalidEntriesFor =
        unit:
        lib.mapAttrsToList (name: _: "${unit.id}/${name}") (
          lib.filterAttrs (
            name: kind: !entryIsValid name kind (builtins.pathExists (unit.path + "/${name}/module.nix"))
          ) (builtins.readDir unit.path)
        );
      violations = lib.concatMap invalidEntriesFor units;
      forbiddenPresent = builtins.filter (
        path: builtins.pathExists (self + "/${path}")
      ) forbiddenOwnership;
      uniqueCheckParts = helpers.mergeCheckParts [
        { alpha = "first"; }
        { beta = "second"; }
      ];
      emptyCheckParts = helpers.mergeCheckParts [ ];
      duplicateCheckPartResult = builtins.tryEval (
        builtins.deepSeq (helpers.mergeCheckParts [
          { duplicated = "first"; }
          { duplicated = "second"; }
        ]) true
      );
      invalidValidFixtures = builtins.filter (entry: !fixtureIsValid entry) fixture.valid;
      unexpectedValidFixtures = builtins.filter fixtureIsValid fixture.invalid;
    in
    assert lib.assertMsg (
      uniqueCheckParts == {
        alpha = "first";
        beta = "second";
      }
    ) "check part merge changed a unique ID";
    assert lib.assertMsg (emptyCheckParts == { }) "empty check parts did not produce an empty set";
    assert lib.assertMsg (
      !duplicateCheckPartResult.success
    ) "duplicate check part ID was silently overwritten";
    assert lib.assertMsg (invalidValidFixtures == [ ]) (
      "valid structure layer fixtures were rejected: ${builtins.toJSON invalidValidFixtures}"
    );
    assert lib.assertMsg (unexpectedValidFixtures == [ ]) (
      "invalid structure layer fixtures were accepted: ${builtins.toJSON unexpectedValidFixtures}"
    );
    assert lib.assertMsg (forbiddenPresent == [ ]) (
      "forbidden ownership paths exist: " + lib.concatStringsSep " " forbiddenPresent
    );
    assert lib.assertMsg (violations == [ ]) (
      "unit contains an entry outside its layer or ownership set: " + lib.concatStringsSep " " violations
    );
    pkgs.runCommandLocal "check-structure-layer-names" { } "touch $out";

  # 文書の種別ごとに読み手が明示されている
  docs-reader = pkgs.runCommandLocal "check-docs-reader" { } ''
    set -euo pipefail
    missing=""
    for kind in operations reference architecture; do
      for doc in ${self}/docs/$kind/*.md; do
        grep -q '^\*\*読み手:\*\*' "$doc" || missing="$missing $doc"
      done
    done
    if [ -n "$missing" ]; then
      echo "docs missing a reader statement:$missing" >&2
      exit 1
    fi
    touch $out
  '';

  # 固定した制約の一覧が実際の check 集合と一致する
  docs-constraint-coverage =
    pkgs.runCommandLocal "check-docs-constraint-coverage"
      {
        checkNames = allCheckNames;
      }
      ''
        set -euo pipefail
        list=${self}/docs/reference/verified-constraints.md

        # 文書のどこかに名前があれば通る形だと、制約行と対応していなくても
        # 緑になる。表の最終列だけを対応表として読む
        awk -F '|' '/^\|/ { print $(NF - 1) }' "$list" \
          | grep -o '`[a-z][a-z0-9-]*`' | tr -d '`' | sort -u > documented

        undocumented=""
        for name in $checkNames; do
          grep -qFx "$name" documented || undocumented="$undocumented $name"
        done
        if [ -n "$undocumented" ]; then
          echo "checks missing from the verified constraint list:$undocumented" >&2
          exit 1
        fi

        stale=""
        for name in $(awk -F '|' '/^\|/ { print $(NF - 1) }' "$list" \
          | grep -o '`[a-z][a-z0-9-]*`' | tr -d '`' | sort -u); do
          case " $checkNames " in
            *" $name "*) ;;
            *) stale="$stale $name" ;;
          esac
        done
        if [ -n "$stale" ]; then
          echo "verified constraint list names a check that does not exist:$stale" >&2
          exit 1
        fi

        touch $out
      '';

  # 文書の相互参照。移動と参照切れを build で落とす
  docs-links = pkgs.testers.lycheeLinkCheck {
    # 文書は宣言 file を参照するため、site は checkout 全体にする
    site = self;
    extraConfig.offline = true;
  };

  # link 先が解決しても、表示名が別の path を名乗っていれば読み手は迷う。
  # 実際に rebuild/module.nix という表示が commands/ 配下へ移った後も残っていた
  docs-path-labels =
    pkgs.runCommandLocal "check-docs-path-labels"
      {
        nativeBuildInputs = with pkgs; [
          coreutils
          gnugrep
          gnused
        ];
      }
      ''
        set -euo pipefail

        missing=""
        while IFS= read -r doc; do
          # 大文字を含む token は NAME のような雛形なので対象にしない
          while IFS= read -r label; do
            [ -e "${self}/$label" ] || missing="$missing ''${doc#${self}/}:$label"
          done < <(
            grep -ohE '`[a-z0-9_.-]+/[a-z0-9_./-]+\.(nix|sh|md|yaml|yml|json|py|ts)`' "$doc" \
              | tr -d '`' | sort -u || true
          )
          # skill や agent の資産は例示の path を含む。対象はこの repository の文書
        done < <(find ${self}/README.md ${self}/CONTRIBUTING.md ${self}/docs -name '*.md' -not -path '*/superpowers/*')

        if [ -n "$missing" ]; then
          echo "documentation names a path that does not exist:$missing" >&2
          exit 1
        fi
        touch $out
      '';

  actionlint = pkgs.runCommandLocal "check-actionlint" { nativeBuildInputs = [ pkgs.actionlint ]; } ''
    workflow_dir=${self}/.github/workflows
    test -n "$(find "$workflow_dir" -type f \( -name '*.yml' -o -name '*.yaml' \) -print -quit)"
    find "$workflow_dir" -type f \( -name '*.yml' -o -name '*.yaml' \) -exec actionlint {} +
    touch $out
  '';

  deadnix = pkgs.runCommandLocal "check-deadnix" { nativeBuildInputs = [ pkgs.deadnix ]; } ''
    deadnix --fail ${self}
    touch $out
  '';

  shellcheck =
    let
      generatedShellActualFile = pkgs.writeText "generated-shell-roster.json" (
        builtins.toJSON generatedShellActual
      );
    in
    pkgs.runCommandLocal "check-shellcheck"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.diffutils
          pkgs.findutils
          pkgs.jq
          pkgs.shellcheck
        ];
      }
      ''
        set -euo pipefail

        expected=${./fixtures/generated-shell-roster.json}
        actual=${generatedShellActualFile}

        jq -e '
          (.agentmemoryHooks | length) > 0 and
          (.commands | length) > 0 and
          (.mcpFronts | length) > 0 and
          (.host | length) > 0
        ' "$expected" >/dev/null

        checkoutCount=0
        while IFS= read -r -d "" source; do
          shellcheck --severity=warning "$source"
          checkoutCount=$((checkoutCount + 1))
        done < <(
          find ${self} -type f -not -path '*/.git/*' -exec \
            sh -c 'head -c 2 "$1" | grep -q "^#!"' _ {} \; -print0
        )
        test "$checkoutCount" -gt 0

        isGeneratedShell() {
          local source=$1 shebang
          test -f "$source"
          shebang=$(head -n 1 "$source")
          case "$shebang" in
            *'/bash' | *'/sh') return 0 ;;
            *) return 1 ;;
          esac
        }

        lintGenerated() {
          local source=$1
          isGeneratedShell "$source"
          shellcheck --severity=warning "$source"
        }

        jq -r '.agentmemoryHooks[]' "$expected" | sort > expected-hooks
        find "$(jq -r '.agentmemoryHooks' "$actual")/bin" \
          -maxdepth 1 -type f -o -type l \
          | while IFS= read -r hook; do basename "$hook"; done \
          | sort > actual-hooks
        diff -u expected-hooks actual-hooks
        while IFS= read -r hook; do
          lintGenerated "$(jq -r '.agentmemoryHooks' "$actual")/bin/$hook"
        done < expected-hooks

        jq -S '.commands' "$expected" > expected-commands.json
        jq -S '.commands | with_entries(.value |= split("/")[-1])' "$actual" \
          > actual-commands.json
        diff -u expected-commands.json actual-commands.json
        jq -S '.commandSmoke.timeoutArgs' "$expected" > expected-command-smoke-timeout.json
        jq -S '.commandSmoke.timeoutArgs' "$actual" > actual-command-smoke-timeout.json
        diff -u expected-command-smoke-timeout.json actual-command-smoke-timeout.json
        jq -e 'any(.commandSmoke.timeoutArgs[]; startswith("--kill-after="))' "$actual" >/dev/null
        mapfile -t commandSmokeTimeoutArgs < <(jq -r '.commandSmoke.timeoutArgs[]' "$actual")
        # elapsed の閾値ではなく、GNU timeout が KILL した status を固定する。
        set +e
        {
          timeout --kill-after=0.10s 0.05s env --ignore-signal=TERM sleep 1
          hardTimeoutStatus=$?
        } 2>/dev/null
        set -e
        if [ "$hardTimeoutStatus" -ne 137 ]; then
          echo "hard timeout canary was not killed: status=$hardTimeoutStatus" >&2
          exit 1
        fi
        while IFS=$'\t' read -r id command; do
          lintGenerated "$command"
          timeout "''${commandSmokeTimeoutArgs[@]}" "$command" --help > "$id-help"
          test -s "$id-help"
        done < <(jq -r '.commands | to_entries[] | [.key, .value] | @tsv' "$actual")

        jq -S '.host' "$expected" > expected-host.json
        jq -S '.host | with_entries(.value |= split("/")[-1])' "$actual" > actual-host.json
        diff -u expected-host.json actual-host.json
        lintGenerated "$(jq -r '.host.wslview' "$actual")"

        jq -S '.mcpFronts' "$expected" > expected-fronts.json
        jq -S '.mcpFronts | keys' "$actual" > actual-fronts.json
        diff -u expected-fronts.json actual-fronts.json
        while IFS=$'\t' read -r id command; do
          inspected=0
          for token in $command; do
            test -f "$token" || continue
            isGeneratedShell "$token" || continue
            inspected=$((inspected + 1))
            lintGenerated "$token"
          done
          if [ "$inspected" -lt 1 ]; then
            echo "no generated shell wrapper found for MCP front: $id" >&2
            exit 1
          fi
        done < <(jq -r '.mcpFronts | to_entries[] | [.key, .value] | @tsv' "$actual")

        touch $out
      '';

  statix = pkgs.runCommandLocal "check-statix" { nativeBuildInputs = [ pkgs.statix ]; } ''
    statix check --config ${self} ${self}
    touch $out
  '';

  nixfmt = pkgs.runCommandLocal "check-nixfmt" { nativeBuildInputs = [ pkgs.nixfmt-tree ]; } ''
    cp -r --no-preserve=mode ${self} source
    treefmt --ci --tree-root "$PWD/source"
    touch $out
  '';

  development-tool-ownership =
    let
      systemPackageNames = map lib.getName hostConfig.environment.systemPackages;
      homePackageNames = map lib.getName homeConfig.home.packages;
      nixDirenvSource = "${homeConfig.programs.direnv.nix-direnv.package}/share/nix-direnv/direnvrc";
      binaryCaches = hostConfig.dotfiles.host.binaryCaches;
      devenvCache = lib.findFirst (
        cache: cache.name == "devenv"
      ) (throw "devenv cache is missing") binaryCaches;
      substituters = map (lib.removeSuffix "/") hostConfig.nix.settings.substituters;
      trustedPublicKeys = hostConfig.nix.settings.trusted-public-keys;
    in
    assert !hostConfig.programs.direnv.enable;
    assert homeConfig.programs.direnv.enable;
    assert homeConfig.programs.direnv.enableBashIntegration;
    assert homeConfig.programs.direnv.nix-direnv.enable;
    assert
      lib.intersectLists [
        "devenv"
        "direnv"
        "nix-direnv"
      ] systemPackageNames == [ ];
    assert lib.elem "devenv" homePackageNames;
    assert lib.elem "direnv" homePackageNames;
    assert toString homeConfig.xdg.configFile."direnv/lib/hm-nix-direnv.sh".source == nixDirenvSource;
    assert lib.count (substituter: substituter == devenvCache.substituter) substituters == 1;
    assert lib.count (key: key == devenvCache.publicKey) trustedPublicKeys == 1;
    assert lib.count (substituter: substituter == "https://cache.nixos.org") substituters == 1;
    assert lib.count (lib.hasPrefix "cache.nixos.org-1:") trustedPublicKeys == 1;
    pkgs.runCommandLocal "check-development-tool-ownership" { } ''
      touch $out
    '';
}
