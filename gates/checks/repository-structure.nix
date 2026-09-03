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

  forbiddenOwnership = [
    "mcp/memory/package/engine"
    "mcp/memory/assets/engine-config.yaml"
    "mcp/searxng/assets/settings.yml"
  ];

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
        done < ${../fixtures/container-agent-reverse-dependencies.txt}
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
      unitTree = import ../fixtures/unit-tree.nix;
      fixtureCollectUnits = import ../impl/collect-units.nix {
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
      fixture = import ../fixtures/structure-unit-directory-names.nix;
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
        import ../fixtures/option-namespace-definition-ownership.nix (
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
        ../fixtures/invalid/missing-rosters.nix
        ../fixtures/invalid/unknown-account.nix
        ../fixtures/invalid/unknown-agent.nix
        ../fixtures/invalid/unknown-container.nix
        ../fixtures/invalid/unknown-lsp.nix
        ../fixtures/invalid/unknown-provider.nix
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
              "sonarqube"
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
      fixture = import ../fixtures/structure-layer-names.nix;
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
      forbiddenDiagnostic = "forbidden ownership paths exist: ${lib.concatStringsSep " " forbiddenPresent}";
      violationDiagnostic = "unit contains an entry outside its layer or ownership set: ${lib.concatStringsSep " " violations}";
      noForbiddenOwnership = forbiddenPresent == [ ];
      noLayerViolations = violations == [ ];
      validFixturesAccepted = invalidValidFixtures == [ ];
      invalidFixturesRejected = unexpectedValidFixtures == [ ];
      validFixtureDiagnostic = "valid structure layer fixtures were rejected: ${builtins.toJSON invalidValidFixtures}";
      invalidFixtureDiagnostic = "invalid structure layer fixtures were accepted: ${builtins.toJSON unexpectedValidFixtures}";
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
    assert lib.assertMsg validFixturesAccepted validFixtureDiagnostic;
    assert lib.assertMsg invalidFixturesRejected invalidFixtureDiagnostic;
    assert lib.assertMsg noForbiddenOwnership forbiddenDiagnostic;
    assert lib.assertMsg noLayerViolations violationDiagnostic;
    pkgs.runCommandLocal "check-structure-layer-names" { } "touch $out";

}
