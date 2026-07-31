{
  description = "NixOS on WSL2";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    nixos-wsl.url = "github:nix-community/NixOS-WSL/release-26.05";
    nixos-wsl.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    # vendored な agent/skill source、flake = false で plain tree 扱い
    superpowers = {
      url = "github:obra/superpowers/v5.1.0";
      flake = false;
    };
    openaiPlugins = {
      url = "github:openai/plugins/ed8ce2eacc07964f0f556519e0737a420da14e00";
      flake = false;
    };
    claudePlugins = {
      url = "github:anthropics/claude-plugins-official/ae21a9367949f92df4e31231d7efe43eaa08207c";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-wsl,
      home-manager,
      sops-nix,
      superpowers,
      openaiPlugins,
      claudePlugins,
      ...
    }:
    let
      system = "x86_64-linux";
      hostName = "nixos";

      pluginSources = {
        inherit superpowers;
        openai-plugins = openaiPlugins;
        claude-plugins-official = claudePlugins;
      };

      # unit の収集。module.nix / package.nix / checks.nix / impl のいずれかを持つ directory が unit
      collectUnits =
        root:
        let
          inherit (nixpkgs) lib;
          isUnit =
            path:
            let
              inner = builtins.readDir path;
            in
            (inner ? "module.nix")
            || (inner ? "package.nix")
            || (inner ? "checks.nix")
            || ((inner."impl" or null) == "directory");
          walk =
            prefix: path:
            let
              inner = lib.filterAttrs (_: kind: kind == "directory") (builtins.readDir path);
              children = lib.concatMap (name: walk "${prefix}${name}/" (path + "/${name}")) (
                builtins.attrNames inner
              );
            in
            (lib.optional (isUnit path) {
              id = lib.removeSuffix "/" prefix;
              inherit path;
            })
            ++ children;
          dirs = lib.filterAttrs (_: kind: kind == "directory") (builtins.readDir root);
        in
        lib.concatMap (name: walk "${name}/" (root + "/${name}")) (builtins.attrNames dirs);

      units = collectUnits ./.;

      unitModules = builtins.filter builtins.pathExists (map (unit: unit.path + "/module.nix") units);

      mkNixosSystem =
        machineModule:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit pluginSources; };
          modules = unitModules ++ [
            ./modules

            nixos-wsl.nixosModules.default
            sops-nix.nixosModules.sops
            home-manager.nixosModules.home-manager

            machineModule
          ];
        };

      maintenancePkgs = nixpkgs.legacyPackages.${system};
    in
    {
      nixosConfigurations.${hostName} = mkNixosSystem {
        # マシン固有の値のみ、他は modules/options.nix の default
        my = {
          accounts = [
            "account-1"
            "account-2"
            "account-3"
          ];
          workIdentity = "~/projects/business/";
        };
      };

      packages.${system} =
        let
          hostConfig = self.nixosConfigurations.${hostName}.config;
          inherit (self.nixosConfigurations.${hostName}) pkgs;
        in
        {
          inherit (pkgs) age sops;
          sourceSnapshot = pkgs.runCommand "dotfiles-source-snapshot" { } ''
            mkdir -p "$out"
            cp -R --preserve=mode ${self}/. "$out/"
            test -x "$out/bootstrap/impl/bootstrap.sh"
          '';
          # 初回 system closure の前、または current generation の command 更新前に checkout から呼ぶ
          dotfiles-install-clis = hostConfig.my.commands.installClis;
          dotfiles-rebuild = hostConfig.my.commands.rebuild;
          dotfiles-sync-images = hostConfig.my.commands.syncImages;
          dotfiles-sops-enroll = hostConfig.my.commands.sopsEnroll;
        };

      devShells.${system}.default = maintenancePkgs.mkShellNoCC {
        packages = self.nixosConfigurations.${hostName}.config.my.devShellPackages;
      };

      formatter.${system} = maintenancePkgs.nixfmt-tree;

      checks.${system} =
        let
          # unit の収集。module.nix / package.nix / impl のいずれかを持つ directory が unit
          # 各 unit の checks.nix を集め、id の重複を拒否する
          mergeChecks =
            args: units:
            let
              files = builtins.filter builtins.pathExists (map (unit: unit.path + "/checks.nix") units);
              # 名前は attrset の spine だけで決まるので、値が allCheckNames を参照しても循環しない
              perUnit = map (file: import file (args // { inherit allCheckNames; })) files;
              names = lib.concatMap builtins.attrNames perUnit;
              allCheckNames = builtins.attrNames checkSet ++ names;
            in
            if names == lib.unique names then
              lib.foldl' (acc: set: acc // set) { } perUnit
            else
              throw "duplicate check id across units: ${
                lib.concatStringsSep " " (lib.unique (lib.filter (n: lib.count (m: m == n) names > 1) names))
              }";

          hostConfig = self.nixosConfigurations.${hostName}.config;
          inherit (self.nixosConfigurations.${hostName}) pkgs;
          inherit (pkgs) lib;
          homeConfig = hostConfig.home-manager.users.${hostConfig.my.username};
          artifactVariantConfig =
            (mkNixosSystem {
              my = {
                accounts = [ ];
                gatewayPort = 9876;
              };
            }).config;

          mkMcpServer = pkgs.callPackage ./pkgs/mk-mcp-server.nix { };
          fakeChromium = pkgs.writeShellScriptBin "chromium" "exit 0";
          fakePlaywright = pkgs.writeShellApplication {
            name = "playwright-mcp";
            runtimeInputs = [ pkgs.coreutils ];
            text = ''
              output_dir=
              while (( $# > 0 )); do
                case $1 in
                  --output-dir)
                    output_dir=$2
                    shift 2
                    ;;
                  *)
                    shift
                    ;;
                esac
              done

              test -n "$output_dir"
              printf '%s\n' "$output_dir" >> "$PLAYWRIGHT_MCP_TEST_LOG"
              printf 'session-scoped\n' > "$output_dir/result.txt"
              printf '%s\n' "$$" > "$output_dir/child.pid"
              if [[ -n ''${PLAYWRIGHT_MCP_TEST_CHILD_LOG:-} ]]; then
                printf '%s\n' "$$" > "$PLAYWRIGHT_MCP_TEST_CHILD_LOG"
              fi

              case ''${PLAYWRIGHT_MCP_TEST_MODE:-pass} in
                wait)
                  while [[ ! -e $PLAYWRIGHT_MCP_TEST_RELEASE ]]; do
                    sleep 0.05
                  done
                  ;;
                fail)
                  exit 23
                  ;;
                stdio)
                  IFS= read -r request
                  printf '%s\n' "$request" > "$PLAYWRIGHT_MCP_TEST_STDIN_LOG"
                  ;;
                interrupt)
                  kill -INT "$PPID"
                  while true; do
                    sleep 0.05
                  done
                  ;;
              esac
            '';
          };
          playwrightRuntimeTest = pkgs.callPackage ./pkgs/playwright-mcp {
            inherit mkMcpServer;
            chromium = fakeChromium;
            playwrightMcp = fakePlaywright;
          };
          agentgatewayService = hostConfig.systemd.services.agentgateway.serviceConfig;

          agentmemoryTemplate = hostConfig.sops.templates."agentmemory.env";
          agentmemoryEnvironmentFiles =
            hostConfig.virtualisation.oci-containers.containers.agentmemory.environmentFiles;
          agentmemoryApiKeyLine = "OPENAI_API_KEY=${hostConfig.sops.placeholder."opencode/go_api_key"}";
          agentmemoryTemplateFile = pkgs.writeText "agentmemory.env" agentmemoryTemplate.content;
          configArtifacts = hostConfig.my.configArtifacts;
          artifactSource = id: configArtifacts.${id}.source;
          artifactSourcesFor =
            format:
            map (artifact: artifact.source) (
              builtins.attrValues (lib.filterAttrs (_: artifact: artifact.format == format) configArtifacts)
            );
          codexSystemConfig = artifactSource "clis/codex/system";
          codexProjectHomePath = "${lib.removePrefix "${hostConfig.my.homeDir}/" hostConfig.my.dotfilesDir}/.codex/config.toml";
          codexProjectConfig = homeConfig.home.file.${codexProjectHomePath}.source;
          codexSeedConfig = artifactSource "clis/codex/user-seed";
          codexWritableRoot = "${hostConfig.my.dotfilesDir}/.git";
          doctorManifest = hostConfig.environment.etc."dotfiles/doctor.json".source;
          nixImageIdentityFiles = hostConfig.my.commands.doctor.nixImageIdentityFiles;
          fixtureNixImageFile = pkgs.writeText "fixture-agentmemory.tar.gz" "fixture";
          fixtureNixImageIdentityData = {
            schemaVersion = 1;
            imageReference = "agentmemory:fixture";
            imageFile = fixtureNixImageFile;
            imageId = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
          };
          fixtureNixImageIdentity = pkgs.writeText "fixture-nix-image-identity-v1.json" (
            builtins.toJSON fixtureNixImageIdentityData
          );
          fixtureNixImageIdentityMalformed = pkgs.writeText "fixture-nix-image-identity-malformed.json" "{";
          fixtureNixImageIdentitySchema = pkgs.writeText "fixture-nix-image-identity-schema.json" (
            builtins.toJSON (fixtureNixImageIdentityData // { schemaVersion = 2; })
          );
          fixtureNixImageIdentityReference = pkgs.writeText "fixture-nix-image-identity-reference.json" (
            builtins.toJSON (fixtureNixImageIdentityData // { imageReference = "other:fixture"; })
          );
          fixtureNixImageIdentityFile = pkgs.writeText "fixture-nix-image-identity-file.json" (
            builtins.toJSON (fixtureNixImageIdentityData // { imageFile = "/nix/store/other.tar.gz"; })
          );
          fixtureNixImageIdentityId = pkgs.writeText "fixture-nix-image-identity-id.json" (
            builtins.toJSON (fixtureNixImageIdentityData // { imageId = "not-an-image-id"; })
          );
          fixtureNixImageIdentityCases = pkgs.writeText "fixture-nix-image-identity-cases.json" (
            builtins.toJSON {
              valid = fixtureNixImageIdentity;
              malformed = fixtureNixImageIdentityMalformed;
              schema = fixtureNixImageIdentitySchema;
              reference = fixtureNixImageIdentityReference;
              imageFile = fixtureNixImageIdentityFile;
              imageId = fixtureNixImageIdentityId;
            }
          );
          homeFiles = homeConfig.home.file;
          directHomeFilesIn =
            directory:
            lib.sort builtins.lessThan (
              map (lib.removePrefix "${directory}/") (
                builtins.filter (
                  path:
                  let
                    relative = lib.removePrefix "${directory}/" path;
                  in
                  lib.hasPrefix "${directory}/" path && !lib.hasInfix "/" relative
                ) (builtins.attrNames homeFiles)
              )
            );
          expectedAgents = lib.mapAttrs (
            _: cli:
            if cli.agentsDir == null then
              null
            else
              {
                directory = "${hostConfig.my.homeDir}/${cli.agentsDir}";
                files = directHomeFilesIn cli.agentsDir;
              }
          ) hostConfig.my.clis;
          expectedAgentsJson = (pkgs.formats.json { }).generate "doctor-agents.json" expectedAgents;
          expectedWslInteropJson =
            (pkgs.formats.json { }).generate "doctor-wsl-interop.json"
              hostConfig.my.doctor.wslInterop;
          expectedDoctorUnits = lib.mapAttrsToList (id: unit: {
            inherit id;
            expected = lib.filterAttrs (_: value: value != null) unit.expected;
          }) hostConfig.my.doctor.units;
          expectedDoctorUnitsJson = (pkgs.formats.json { }).generate "doctor-units.json" expectedDoctorUnits;
          expectedManagedFiles = lib.mapAttrsToList (id: file: {
            inherit id;
            inherit (file) path source;
          }) hostConfig.my.doctor.managedFiles;
          expectedManagedFilesJson =
            (pkgs.formats.json { }).generate "doctor-managed-files.json"
              expectedManagedFiles;
          expectedCliContracts = map (
            name:
            let
              cli = hostConfig.my.clis.${name};
            in
            {
              inherit name;
              binaryName = cli.binary;
              binaryPath = "${hostConfig.my.homeDir}/.local/bin/${cli.binary}";
              rules = {
                path = "${hostConfig.my.homeDir}/${cli.rulesFile}";
                source = homeFiles.${cli.rulesFile}.source;
              };
              skills = {
                directory = "${hostConfig.my.homeDir}/${cli.skillsDir}";
                names = directHomeFilesIn cli.skillsDir;
              };
              agents = expectedAgents.${name};
              gatewayFile =
                if cli.gatewayFile == null then
                  null
                else
                  {
                    path = "${hostConfig.my.homeDir}/${cli.gatewayFile}";
                    source = homeFiles.${cli.gatewayFile}.source;
                  };
            }
          ) (builtins.attrNames hostConfig.my.clis);
          expectedCliContractsJson = (pkgs.formats.json { }).generate "doctor-clis.json" expectedCliContracts;
          expectedMcpTargetsJson = (pkgs.formats.json { }).generate "doctor-mcp-targets.json" (
            builtins.attrNames hostConfig.my.mcp.targets
          );
          expectedProbePolicyJson =
            (pkgs.formats.json { }).generate "doctor-probe-policy.json"
              hostConfig.my.doctor.probePolicy;
          expectedConfigArtifactFormats = {
            "clis/antigravity/mcp" = "json";
            "clis/claude/managed-mcp" = "json";
            "clis/claude/managed-settings" = "json";
            "clis/claude/user-settings-seed" = "json";
            "clis/codex/project" = "toml";
            "clis/codex/system" = "toml";
            "clis/codex/user-seed" = "toml";
            "clis/opencode/config" = "json";
            "mcp/agentgateway/config" = "yaml";
            "mcp/agentmemory/config" = "yaml";
            "mcp/searxng/settings-template" = "yaml";
          }
          // lib.optionalAttrs (hostConfig.my.accounts != [ ]) {
            "accounts/gh-hosts" = "yaml";
          };
          actualConfigArtifactFormats = lib.mapAttrs (_: artifact: artifact.format) configArtifacts;
          variantConfigArtifactFormats = lib.mapAttrs (
            _: artifact: artifact.format
          ) artifactVariantConfig.my.configArtifacts;
          variantClaudeMcp = artifactVariantConfig.my.configArtifacts."clis/claude/managed-mcp".source;
          expectedDoctorOciImagesJson = (pkgs.formats.json { }).generate "doctor-oci-images.json" (
            lib.mapAttrsToList (id: image: {
              inherit id;
              inherit (image)
                kind
                container
                image
                repository
                digest
                ;
              unit = "docker-${image.container}.service";
              imageFile = if image.imageFile == null then null else toString image.imageFile;
              expectedImageIdFile = if image.kind == "nix" then toString nixImageIdentityFiles.${id} else null;
            }) hostConfig.my.ociImages
          );
          syncImages = hostConfig.my.commands.syncImages;
          codexProjectRuntimePath = "${hostConfig.my.dotfilesDir}/.codex/config.toml";
          wslRestartRequired = hostConfig.my.commands.wslRestartRequired;
          wslConfig = hostConfig.environment.etc."wsl.conf".source;
          failingCmp = pkgs.writeShellScript "cmp-always-fails" "exit 2";
          failingManifestCmp = pkgs.writeShellScript "cmp-manifest-fails" ''
            if [[ $3 == */init-interface-version ]]; then
              exec ${pkgs.coreutils}/bin/cmp "$@"
            fi
            exit 2
          '';

          jsonConfigs = artifactSourcesFor "json";
          tomlConfigs = artifactSourcesFor "toml";
          yamlConfigs = artifactSourcesFor "yaml";

          asArgs = files: lib.concatMapStringsSep " " (f: "${f}") files;
          checkSet = {
            nixos-toplevel = self.nixosConfigurations.${hostName}.config.system.build.toplevel;

            # 配備する package そのものを build し、同梱の downstream lifecycle test を実行する
            agentgateway-session-lifecycle =
              let
                agentgateway = pkgs.callPackage ./pkgs/agentgateway { };
              in
              assert lib.hasPrefix "${agentgateway}/bin/agentgateway " agentgatewayService.ExecStart;
              agentgateway;

            config-artifact-contract =
              assert actualConfigArtifactFormats == expectedConfigArtifactFormats;
              assert
                variantConfigArtifactFormats
                == builtins.removeAttrs expectedConfigArtifactFormats [ "accounts/gh-hosts" ];
              assert !(builtins.hasAttr "gh-hosts.yml" artifactVariantConfig.sops.templates);
              assert
                hostConfig.environment.etc."claude-code/managed-settings.json".source
                == artifactSource "clis/claude/managed-settings";
              assert
                hostConfig.environment.etc."claude-code/managed-mcp.json".source
                == artifactSource "clis/claude/managed-mcp";
              assert hostConfig.environment.etc."codex/config.toml".source == artifactSource "clis/codex/system";
              assert codexProjectConfig == artifactSource "clis/codex/project";
              assert
                homeConfig.home.file.".config/opencode/opencode.json".source
                == artifactSource "clis/opencode/config";
              assert
                homeConfig.home.file.".gemini/antigravity-cli/mcp_config.json".source
                == artifactSource "clis/antigravity/mcp";
              assert
                hostConfig.environment.etc."agentgateway/config.yaml".source
                == artifactSource "mcp/agentgateway/config";
              # soft 上限の暫定封じ込め、session 解放の代替にはしない
              assert agentgatewayService.LimitNOFILE == "4096:4096";
              assert lib.elem "${artifactSource "mcp/agentmemory/config"}:/app/config.yaml:ro"
                hostConfig.virtualisation.oci-containers.containers.agentmemory.volumes;
              assert
                hostConfig.sops.templates."searxng-settings.yml".content
                == builtins.readFile (artifactSource "mcp/searxng/settings-template");
              assert
                hostConfig.my.accounts == [ ]
                ||
                  hostConfig.sops.templates."gh-hosts.yml".content
                  == builtins.readFile (artifactSource "accounts/gh-hosts");
              pkgs.runCommandLocal "check-config-artifact-contract"
                {
                  nativeBuildInputs = [
                    pkgs.jq
                    pkgs.taplo
                    pkgs.yq
                  ];
                }
                ''
                    jq --exit-status \
                      --arg expected ${lib.escapeShellArg hostConfig.my.gatewayUrl} \
                      '.mcpServers.gateway.url == $expected' \
                      ${artifactSource "clis/claude/managed-mcp"} > /dev/null
                    jq --exit-status \
                      --arg expected 'http://localhost:9876/mcp' \
                      '.mcpServers.gateway.url == $expected' \
                      ${variantClaudeMcp} > /dev/null
                    jq --exit-status \
                      --arg expected ${lib.escapeShellArg hostConfig.my.gatewayUrl} \
                      '.mcpServers.gateway.serverUrl == $expected' \
                      ${artifactSource "clis/antigravity/mcp"} > /dev/null
                    jq --exit-status \
                      --arg expected ${lib.escapeShellArg hostConfig.my.gatewayUrl} \
                      '.mcp.gateway.url == $expected' \
                      ${artifactSource "clis/opencode/config"} > /dev/null
                    test "$(taplo get --output-format json --file-path ${artifactSource "clis/codex/system"} mcp_servers.gateway.url | jq -r .)" = \
                      ${lib.escapeShellArg hostConfig.my.gatewayUrl}
                    test "$(taplo get --output-format json --file-path ${artifactSource "clis/codex/user-seed"} model | jq -r .)" = \
                      gpt-5.6-sol
                    test "$(yq -r '.config.mcp.sessionTtl' ${artifactSource "mcp/agentgateway/config"})" = 30m
                    test "$(yq -r '.workers[] | select(.name == "iii-http") | .config.port' ${artifactSource "mcp/agentmemory/config"})" = 3111
                    test "$(yq -r '.workers[] | select(.name == "iii-stream") | .config.port' ${artifactSource "mcp/agentmemory/config"})" = 3112
                    test "$(yq -r '.server.port' ${artifactSource "mcp/searxng/settings-template"})" = 8080
                    test "$(yq -r '.valkey.url' ${artifactSource "mcp/searxng/settings-template"})" = valkey://valkey:6379/0
                  touch $out
                '';

            playwright-runtime =
              assert (agentgatewayService.RuntimeDirectory or null) == "agentgateway";
              assert (agentgatewayService.RuntimeDirectoryMode or null) == "0700";
              assert lib.elem "PLAYWRIGHT_MCP_RUNTIME_DIR=/run/agentgateway" agentgatewayService.Environment;
              pkgs.runCommandLocal "check-playwright-runtime"
                {
                  nativeBuildInputs = [
                    pkgs.bash
                    pkgs.coreutils
                    pkgs.gnugrep
                  ];
                }
                ''
                  bash ${self}/scripts/tests/playwright-runtime.sh \
                    ${lib.getExe playwrightRuntimeTest} \
                    ${hostConfig.my.mcp.targets.playwright.command}
                  touch $out
                '';

            wsl-restart-policy = pkgs.runCommandLocal "check-wsl-restart-policy" { } ''
              set -euo pipefail

              mkdir -p booted/etc bad-booted/etc current/etc candidate/etc missing/etc invalid/etc/wsl.conf fake-bin
              cp ${wslConfig} booted/etc/wsl.conf
              cp ${wslConfig} bad-booted/etc/wsl.conf
              cp ${wslConfig} candidate/etc/wsl.conf
              cp ${hostConfig.system.build.toplevel}/init-interface-version current/init-interface-version
              cp ${hostConfig.system.build.toplevel}/init-interface-version candidate/init-interface-version
              chmod u+w bad-booted/etc/wsl.conf candidate/etc/wsl.conf candidate/init-interface-version

              assert_plan() {
                expected=$1
                shift
                actual=$(${lib.getExe wslRestartRequired} --plan \
                  --booted-system booted --current-system current "$@")
                test "$actual" = "$expected"
              }

              assert_invalid_candidate() {
                if ${lib.getExe wslRestartRequired} --plan \
                  --booted-system booted --current-system current candidate 2>/dev/null; then
                  echo "invalid candidate WSL user metadata was accepted" >&2
                  exit 1
                else
                  test "$?" -eq 2
                fi
                cp ${wslConfig} candidate/etc/wsl.conf
              }

              assert_plan switch candidate
              test "$(${lib.getExe wslRestartRequired} --default-user \
                --booted-system booted --current-system current candidate)" = ${lib.escapeShellArg hostConfig.my.username}
              if ${lib.getExe wslRestartRequired} --plan --default-user candidate 2>/dev/null; then
                echo "mutually exclusive output modes were accepted" >&2
                exit 1
              else
                test "$?" -eq 2
              fi

              printf '\n[interop]\nappendWindowsPath=true\n' >> candidate/etc/wsl.conf
              assert_plan switch-restart candidate
              cp ${wslConfig} candidate/etc/wsl.conf

              printf 'incompatible\n' >> candidate/init-interface-version
              assert_plan boot-restart candidate

              printf '\n[interop]\nappendWindowsPath=true\n' >> candidate/etc/wsl.conf
              assert_plan boot-two-stage candidate
              cp ${wslConfig} candidate/etc/wsl.conf
              cp current/init-interface-version candidate/init-interface-version

              sed -i '/^\[user\]$/,/^\[/ s/^default=.*/  default = other-user  /' \
                candidate/etc/wsl.conf
              assert_plan boot-two-stage candidate
              printf 'incompatible\n' >> candidate/init-interface-version
              assert_plan boot-two-stage candidate
              cp ${wslConfig} candidate/etc/wsl.conf
              cp current/init-interface-version candidate/init-interface-version

              sed -i '/^\[user\]$/,$d' candidate/etc/wsl.conf
              assert_invalid_candidate

              sed -i '/^\[user\]$/,/^\[/ s/^default=.*/default=/' candidate/etc/wsl.conf
              assert_invalid_candidate

              sed -i '/^default=/a default=duplicate-user' candidate/etc/wsl.conf
              assert_invalid_candidate

              sed -i '/^\[user\]$/,$d' bad-booted/etc/wsl.conf
              test "$(${lib.getExe wslRestartRequired} --plan \
                --booted-system bad-booted --current-system current candidate)" = boot-two-stage

              test "$(${lib.getExe wslRestartRequired} --plan \
                --booted-system missing --current-system current candidate)" = boot-two-stage
              test "$(${lib.getExe wslRestartRequired} --plan \
                --booted-system booted --current-system missing candidate)" = boot-two-stage

              if ${lib.getExe wslRestartRequired} --quiet \
                --booted-system booted --current-system current candidate; then
                echo "unchanged manifest was classified as restart-required" >&2
                exit 1
              else
                test "$?" -eq 1
              fi

              ${lib.getExe wslRestartRequired} --quiet \
                --booted-system booted --current-system missing candidate

              ln -s ${failingCmp} fake-bin/cmp
              if PATH="$PWD/fake-bin:$PATH" ${pkgs.bash}/bin/bash \
                ${self}/modules/commands/wsl-restart-required \
                --quiet --booted-system booted --current-system current candidate 2>/dev/null; then
                echo "cmp I/O error was accepted" >&2
                exit 1
              else
                test "$?" -eq 2
              fi

              ln -sf ${failingManifestCmp} fake-bin/cmp
              if PATH="$PWD/fake-bin:$PATH" ${pkgs.bash}/bin/bash \
                ${self}/modules/commands/wsl-restart-required \
                --quiet --booted-system booted --current-system current candidate 2>/dev/null; then
                echo "manifest cmp I/O error was accepted" >&2
                exit 1
              else
                test "$?" -eq 2
              fi

              printf 'incompatible\n' >> candidate/init-interface-version
              ${lib.getExe wslRestartRequired} --quiet \
                --booted-system booted --current-system current candidate
              cp current/init-interface-version candidate/init-interface-version

              printf '\n[interop]\nappendWindowsPath=true\n' >> candidate/etc/wsl.conf
              ${lib.getExe wslRestartRequired} --quiet \
                --booted-system booted --current-system current candidate

              ${lib.getExe wslRestartRequired} --quiet \
                --booted-system missing --current-system current candidate

              if ${lib.getExe wslRestartRequired} --quiet \
                --booted-system booted --current-system current missing 2>/dev/null; then
                echo "missing candidate manifest was accepted" >&2
                exit 1
              else
                test "$?" -eq 2
              fi

              if ${lib.getExe wslRestartRequired} --quiet \
                --booted-system booted --current-system current invalid 2>/dev/null; then
                echo "invalid candidate manifest was accepted" >&2
                exit 1
              else
                test "$?" -eq 2
              fi

              test -r ${hostConfig.system.build.toplevel}/etc/wsl.conf
              test -r ${hostConfig.system.build.toplevel}/init-interface-version
              cmp --silent ${wslConfig} ${hostConfig.system.build.toplevel}/etc/wsl.conf
              touch $out
            '';

            rebuild-routing =
              pkgs.runCommandLocal "check-rebuild-routing"
                {
                  nativeBuildInputs = [
                    pkgs.bash
                    pkgs.coreutils
                    pkgs.gnugrep
                    pkgs.gnused
                    pkgs.jq
                    pkgs.util-linux
                  ];
                }
                ''
                  bash ${self}/rebuild/tests/rebuild-routing.sh \
                    ${self}/modules/commands/rebuild \
                    ${pkgs.bash}/bin/bash \
                    ${lib.getExe pkgs.fakeroot} \
                    ${self}/rebuild/impl/lib/atomic-file.sh \
                    ${self}/rebuild/impl/lib/operation-lock.sh \
                    ${self}/rebuild/impl/lib/rebuild-receipt.sh \
                    ${self}/rebuild/impl/lib/rebuild-attempt.sh
                  touch $out
                '';

            rebuild-attempt =
              pkgs.runCommandLocal "check-rebuild-attempt"
                {
                  nativeBuildInputs = [
                    pkgs.bash
                    pkgs.coreutils
                    pkgs.jq
                  ];
                }
                ''
                  bash ${self}/rebuild/tests/rebuild-attempt.sh \
                    ${self}/rebuild/impl/lib/rebuild-attempt.sh
                  touch $out
                '';

            atomic-publication =
              pkgs.runCommandLocal "check-atomic-publication"
                {
                  nativeBuildInputs = [
                    pkgs.bash
                    pkgs.coreutils
                    pkgs.findutils
                    pkgs.gnused
                    pkgs.util-linux
                  ];
                }
                ''
                  bash ${self}/rebuild/tests/atomic-publication.sh \
                    ${self}/rebuild/impl/lib/atomic-file.sh \
                    ${self}/rebuild/impl/lib/operation-lock.sh \
                    ${self}/images/impl/lib/image-state.sh \
                    full
                  bash ${self}/rebuild/tests/atomic-publication.sh \
                    ${self}/rebuild/impl/lib/atomic-file.sh \
                    ${self}/rebuild/impl/lib/operation-lock.sh \
                    ${self}/images/impl/lib/image-state.sh \
                    interop \
                    ${self}/rebuild/fixtures/legacy-operation-lock.sh \
                    ${self}/images/fixtures/legacy-image-state.sh
                  touch $out
                '';

            active-publication =
              pkgs.runCommandLocal "check-active-publication"
                {
                  nativeBuildInputs = [
                    pkgs.bash
                    pkgs.coreutils
                    pkgs.findutils
                    pkgs.gnused
                    pkgs.jq
                  ];
                }
                ''
                  bash ${self}/rebuild/tests/active-publication.sh \
                    ${self}/rebuild/impl/lib/atomic-file.sh \
                    ${self}/rebuild/impl/lib/rebuild-receipt.sh \
                    full
                  touch $out
                '';

            preparation-parent-evidence =
              pkgs.runCommandLocal "check-preparation-parent-evidence"
                {
                  nativeBuildInputs = [
                    pkgs.bash
                    pkgs.coreutils
                    pkgs.jq
                  ];
                }
                ''
                  bash ${self}/rebuild/tests/preparation-parent-evidence.sh \
                    ${self}/rebuild/impl/lib/rebuild-receipt.sh \
                    full
                  touch $out
                '';

            gc-root-observer =
              pkgs.runCommandLocal "check-gc-root-observer"
                {
                  nativeBuildInputs = [
                    pkgs.bash
                    pkgs.coreutils
                    pkgs.findutils
                    pkgs.gnused
                    pkgs.jq
                  ];
                }
                ''
                  bash ${self}/rebuild/tests/gc-root-observer.sh \
                    ${self}/rebuild/impl/lib/rebuild-receipt.sh \
                    full
                  touch $out
                '';

            rebuild-entrypoint =
              let
                systemPackageNames = map lib.getName hostConfig.environment.systemPackages;
                upstreamRebuild = lib.getExe hostConfig.system.build.nixos-rebuild;
                publicRebuild = "${hostConfig.system.path}/bin/nixos-rebuild";
              in
              assert !hostConfig.system.tools.nixos-rebuild.enable;
              assert !(lib.elem "nixos-rebuild-ng" systemPackageNames);
              pkgs.runCommandLocal "check-rebuild-entrypoint" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
                set -euo pipefail
                test -x ${publicRebuild}
                test -x ${upstreamRebuild}
                test "$(readlink -f ${publicRebuild})" != ${upstreamRebuild}
                set +e
                ${publicRebuild} >stdout 2>stderr
                status=$?
                set -e
                test "$status" -eq 2
                test ! -s stdout
                grep -Fqx 'FATAL: direct nixos-rebuild bypasses the dotfiles rebuild transaction' stderr
                grep -Fqx \
                  'Use dotfiles-rebuild for normal changes; use bootstrap/impl/bootstrap.sh only for initial provisioning.' \
                  stderr
                touch $out
              '';

            doctor-runtime =
              pkgs.runCommandLocal "check-doctor-runtime"
                {
                  nativeBuildInputs = [
                    pkgs.bash
                    pkgs.coreutils
                    pkgs.gnugrep
                    pkgs.gnused
                    pkgs.jq
                    pkgs.util-linux
                  ];
                }
                ''
                  bash ${self}/doctor/tests/doctor-runtime.sh \
                    ${self}/modules/commands/doctor \
                    ${self}/rebuild/impl/lib/atomic-file.sh \
                    ${self}/images/impl/lib/image-state.sh \
                    ${pkgs.bash}/bin/bash \
                    ${fixtureNixImageIdentityCases}
                  touch $out
                '';

            doctor-manifest-contract =
              assert lib.all (id: builtins.hasAttr id hostConfig.systemd.units) (
                builtins.attrNames hostConfig.my.doctor.units
              );
              assert builtins.hasAttr "agentgateway.service" hostConfig.my.doctor.units;
              pkgs.runCommandLocal "check-doctor-manifest-contract"
                {
                  nativeBuildInputs = [ pkgs.jq ];
                }
                ''
                  set -euo pipefail

                  jq --exit-status \
                    --arg expectedPolicy ${
                      lib.escapeShellArg (if hostConfig.my.sops.enrollmentState == "enrolled" then "reject" else "warn")
                    } \
                    --argjson expectedSchemaVersion ${toString hostConfig.my.doctor.schemaVersion} \
                    '.schemaVersion == $expectedSchemaVersion and .sops.homeKey.policy == $expectedPolicy' \
                    ${doctorManifest} > /dev/null

                  jq --sort-keys 'sort_by(.id)' ${expectedDoctorUnitsJson} > expected-units.json
                  jq --sort-keys '.units | sort_by(.id)' ${doctorManifest} > actual-units.json
                  diff --unified expected-units.json actual-units.json

                  jq --sort-keys 'sort_by(.id)' ${expectedManagedFilesJson} > expected-managed-files.json
                  jq --sort-keys '.managedFiles | sort_by(.id)' ${doctorManifest} > actual-managed-files.json
                  diff --unified expected-managed-files.json actual-managed-files.json

                  jq --sort-keys 'sort_by(.name)' ${expectedCliContractsJson} > expected-clis.json
                  jq --sort-keys '.clis | sort_by(.name)' ${doctorManifest} > actual-clis.json
                  diff --unified expected-clis.json actual-clis.json

                  jq --sort-keys '.' ${expectedMcpTargetsJson} > expected-mcp-targets.json
                  jq --sort-keys '.mcp.targets' ${doctorManifest} > actual-mcp-targets.json
                  diff --unified expected-mcp-targets.json actual-mcp-targets.json

                  jq --exit-status \
                    --arg expectedHardLimit ${lib.escapeShellArg (builtins.elemAt (lib.splitString ":" agentgatewayService.LimitNOFILE) 1)} \
                    --arg expectedSoftLimit ${lib.escapeShellArg (builtins.elemAt (lib.splitString ":" agentgatewayService.LimitNOFILE) 0)} '
                    .mcp.resources.properties == [
                      "MainPID",
                      "TasksCurrent",
                      "MemoryCurrent",
                      "MemorySwapCurrent",
                      "LimitNOFILE",
                      "LimitNOFILESoft"
                    ] and
                    .mcp.resources.expected.LimitNOFILE == $expectedHardLimit and
                    .mcp.resources.expected.LimitNOFILESoft == $expectedSoftLimit
                  ' ${doctorManifest} > /dev/null

                  jq --exit-status '
                    .mcp.healthUnit == "agentgateway.service" and
                    .mcp.requestedProtocolVersion == "2025-11-25" and
                    .mcp.supportedProtocolVersions == [
                      "2024-11-05",
                      "2025-03-26",
                      "2025-06-18",
                      "2025-11-25"
                    ]
                  ' ${doctorManifest} > /dev/null

                  jq --sort-keys '.' ${expectedProbePolicyJson} > expected-probe-policy.json
                  jq --sort-keys '.probePolicy' ${doctorManifest} > actual-probe-policy.json
                  diff --unified expected-probe-policy.json actual-probe-policy.json

                  jq --sort-keys 'sort_by(.id)' ${expectedDoctorOciImagesJson} > expected-oci-images.json
                  jq --sort-keys '.oci.images | sort_by(.id)' ${doctorManifest} > actual-oci-images.json
                  diff --unified expected-oci-images.json actual-oci-images.json

                  jq --exit-status \
                    --arg stateRoot ${lib.escapeShellArg "${hostConfig.my.homeDir}/.local/state/dotfiles-wsl/image-sync"} \
                    --arg dockerCommand ${lib.escapeShellArg (lib.getExe pkgs.docker)} \
                    --arg syncStatusCommand ${lib.escapeShellArg (lib.getExe syncImages)} '
                      .oci.healthUnit == "docker.service" and
                      .oci.stateRoot == $stateRoot and
                      .oci.dockerCommand == $dockerCommand and
                      .oci.syncStatusCommand == $syncStatusCommand
                    ' ${doctorManifest} > /dev/null

                  jq --sort-keys '
                    [.clis[] | {
                      key: .name,
                      value: (if .agents == null then null else {
                        directory: .agents.directory,
                        files: (.agents.files | sort)
                      } end)
                    }] | from_entries
                  ' ${doctorManifest} > actual-agents.json
                  jq --sort-keys \
                    'with_entries(.value |= if . == null then null else (.files |= sort) end)' \
                    ${expectedAgentsJson} > expected-agents.json
                  diff --unified expected-agents.json actual-agents.json

                  jq --exit-status \
                    --slurpfile expected ${expectedWslInteropJson} \
                    '.wslInterop == $expected[0]' \
                    ${doctorManifest} > /dev/null

                  jq --exit-status \
                    --arg path ${lib.escapeShellArg codexProjectRuntimePath} \
                    --arg source ${lib.escapeShellArg (toString codexProjectConfig)} \
                    'any(.managedFiles[]; .id == "codex-project" and .path == $path and .source == $source)' \
                    ${doctorManifest} > /dev/null

                  jq --exit-status \
                    --arg path ${lib.escapeShellArg "${hostConfig.my.homeDir}/.config/opencode/plugins/agentmemory-capture.ts"} \
                    --arg source ${lib.escapeShellArg (toString hostConfig.my.doctor.managedFiles.agentmemory-opencode-capture.source)} \
                    'any(.managedFiles[];
                      .id == "agentmemory-opencode-capture" and
                      .path == $path and
                      .source == $source
                    )' \
                    ${doctorManifest} > /dev/null

                  touch $out
                '';

            agentmemory-env =
              assert agentmemoryEnvironmentFiles == [ agentmemoryTemplate.path ];
              pkgs.runCommandLocal "check-agentmemory-env" { } ''
                set -eu

                printf '%s\n' \
                  EMBEDDING_PROVIDER \
                  OPENAI_API_KEY \
                  OPENAI_BASE_URL \
                  OPENAI_MODEL \
                  | sort > expected-keys
                cut -d= -f1 ${agentmemoryTemplateFile} | sort > actual-keys
                diff -u expected-keys actual-keys

                grep -Fqx 'OPENAI_BASE_URL=https://opencode.ai/zen/go/v1' ${agentmemoryTemplateFile}
                grep -Fqx 'OPENAI_MODEL=minimax-m2.7' ${agentmemoryTemplateFile}
                grep -Fqx 'EMBEDDING_PROVIDER=none' ${agentmemoryTemplateFile}
                grep -Fqx ${lib.escapeShellArg agentmemoryApiKeyLine} ${agentmemoryTemplateFile}
                touch $out
              '';

            # 各 producer が実配備へ渡す immutable source を形式別に検査する。
            config-syntax =
              pkgs.runCommandLocal "check-config-syntax"
                {
                  nativeBuildInputs = [
                    pkgs.jq
                    pkgs.taplo
                    pkgs.yq
                  ];
                }
                ''
                  for f in ${asArgs jsonConfigs}; do
                    jq empty "$f"
                  done
                  for f in ${asArgs tomlConfigs}; do
                    taplo lint "$f"
                  done
                  for f in ${asArgs yamlConfigs}; do
                    yq . "$f" > /dev/null
                  done
                  for global_config in ${codexSystemConfig} ${codexSeedConfig}; do
                    if taplo get --output-format json --file-path "$global_config" \
                      sandbox_workspace_write.writable_roots > /dev/null 2>&1; then
                      echo "checkout-specific writable root leaked into global config: $global_config" >&2
                      exit 1
                    fi
                  done
                  taplo get --output-format json --file-path ${codexProjectConfig} \
                    sandbox_workspace_write.writable_roots \
                    | jq --exit-status --arg expected ${lib.escapeShellArg codexWritableRoot} \
                      '. == [$expected]' > /dev/null
                  touch $out
                '';
          };
        in
        checkSet
        // mergeChecks {
          inherit
            pkgs
            lib
            self
            hostConfig
            sops-nix
            ;
        } units;
    };
}
