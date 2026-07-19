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

      maintenancePkgs = nixpkgs.legacyPackages.${system};
    in
    {
      nixosConfigurations.${hostName} = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit pluginSources; };
        modules = [
          ./modules

          nixos-wsl.nixosModules.default
          sops-nix.nixosModules.sops
          home-manager.nixosModules.home-manager

          # マシン固有の値のみ、他は modules/options.nix の default
          {
            my = {
              accounts = [
                "account-1"
                "account-2"
                "account-3"
              ];
              workIdentity = "~/projects/business/";
            };
          }
        ];
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
            test -x "$out/scripts/bootstrap.sh"
          '';
          # 初回 system closure の前、または current generation の command 更新前に checkout から呼ぶ
          dotfiles-install-clis = hostConfig.my.commands.installClis;
          dotfiles-rebuild = hostConfig.my.commands.rebuild;
          dotfiles-sops-enroll = hostConfig.my.commands.sopsEnroll;
        };

      devShells.${system}.default = maintenancePkgs.mkShellNoCC {
        packages = with maintenancePkgs; [
          actionlint
          deadnix
          jq
          nixfmt-tree
          shellcheck
          statix
          taplo
          yq
        ];
      };

      formatter.${system} = maintenancePkgs.nixfmt-tree;

      checks.${system} =
        let
          hostConfig = self.nixosConfigurations.${hostName}.config;
          inherit (self.nixosConfigurations.${hostName}) pkgs;
          inherit (pkgs) lib;
          homeConfig = hostConfig.home-manager.users.${hostConfig.my.username};

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
          fakeBootstrapRebuild = pkgs.writeShellScriptBin "nixos-rebuild" ''
            printf '%q ' "$@" >> "$BOOTSTRAP_CALL_LOG"
            printf '\n' >> "$BOOTSTRAP_CALL_LOG"
            if [[ -n ''${BOOTSTRAP_REBUILD_READY:-} ]]; then
              : > "$BOOTSTRAP_REBUILD_READY"
              while [[ ! -e $BOOTSTRAP_REBUILD_RELEASE ]]; do
                sleep 0.01
              done
            fi
          '';
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
          codexSystemConfig = hostConfig.environment.etc."codex/config.toml".source;
          codexProjectHomePath = "${lib.removePrefix "${hostConfig.my.homeDir}/" hostConfig.my.dotfilesDir}/.codex/config.toml";
          codexProjectConfig = homeConfig.home.file.${codexProjectHomePath}.source;
          codexSeedConfig = pkgs.replaceVars ./modules/clis/codex/config.toml {
            codexModel = "dummy-model";
          };
          codexWritableRoot = "${hostConfig.my.dotfilesDir}/.git";
          doctorManifest = hostConfig.environment.etc."dotfiles/doctor.json".source;
          sopsGenerationContract = hostConfig.environment.etc."dotfiles/sops-generation.json".source;
          sopsGenerationContractData = builtins.fromJSON (
            builtins.unsafeDiscardStringContext (builtins.readFile sopsGenerationContract)
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
          expectedProbePolicyJson = (pkgs.formats.json { }).generate "doctor-probe-policy.json" {
            cliTimeoutSeconds = 5;
            systemTimeoutSeconds = 5;
            windowsTimeoutSeconds = 5;
            mcpRequestTimeoutSeconds = 5;
            mcpCleanupTimeoutSeconds = 5;
            totalTimeoutSeconds = 30;
            maxPages = 20;
            maxResponseBytes = 1048576;
          };
          codexProjectRuntimePath = "${hostConfig.my.dotfilesDir}/.codex/config.toml";
          sopsKeyFile = "/var/lib/sops-nix/key.txt";
          sopsKeyDirectoryPolicy = hostConfig.systemd.tmpfiles.settings."sops-key"."/var/lib/sops-nix".d;
          sopsKeyFilePolicy = hostConfig.systemd.tmpfiles.settings."sops-key"."/var/lib/sops-nix/key.txt".z;
          wslRestartRequired = hostConfig.my.commands.wslRestartRequired;
          wslConfig = hostConfig.environment.etc."wsl.conf".source;
          failingCmp = pkgs.writeShellScript "cmp-always-fails" "exit 2";
          failingManifestCmp = pkgs.writeShellScript "cmp-manifest-fails" ''
            if [[ $3 == */init-interface-version ]]; then
              exec ${pkgs.coreutils}/bin/cmp "$@"
            fi
            exit 2
          '';

          # config-syntax check 専用の @var@ 埋め、実際の値は各 module 側にありここでは構文検査用
          dummyVars = {
            gatewayUrl = "http://127.0.0.1:1/mcp";
            httpPort = "1";
            streamPort = "2";
            searxngSecret = "dummy";
            searxngPort = "3";
            valkeyPort = "4";
          };

          jsonConfigs = [
            ./modules/clis/claude/managed-settings.json
            ./modules/clis/claude/settings.json
            (pkgs.replaceVars ./modules/clis/claude/managed-mcp.json {
              inherit (dummyVars) gatewayUrl;
            })
            (pkgs.replaceVars ./modules/clis/antigravity/mcp_config.json {
              inherit (dummyVars) gatewayUrl;
            })
            (pkgs.replaceVars ./modules/clis/opencode/opencode.json { inherit (dummyVars) gatewayUrl; })
          ];

          tomlConfigs = [
            (pkgs.replaceVars ./modules/clis/codex/config-system.toml {
              inherit (dummyVars) gatewayUrl;
            })
            codexProjectConfig
            codexSeedConfig
          ];

          yamlConfigs = [
            (pkgs.replaceVars ./modules/mcp/servers/agentmemory.yaml {
              inherit (dummyVars) httpPort streamPort;
            })
            (pkgs.replaceVars ./modules/mcp/servers/searxng-settings.yml {
              inherit (dummyVars) searxngSecret searxngPort valkeyPort;
            })
          ];

          asArgs = files: lib.concatMapStringsSep " " (f: "${f}") files;
        in
        {
          nixos-toplevel = self.nixosConfigurations.${hostName}.config.system.build.toplevel;

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

          sops-policy =
            assert hostConfig.sops.age.keyFile == sopsKeyFile;
            assert hostConfig.sops.age.generateKey == false;
            assert sopsKeyDirectoryPolicy.type == "d";
            assert sopsKeyDirectoryPolicy.user == "root";
            assert sopsKeyDirectoryPolicy.group == "root";
            assert sopsKeyDirectoryPolicy.mode == "0700";
            assert sopsKeyFilePolicy.type == "z";
            assert sopsKeyFilePolicy.user == "root";
            assert sopsKeyFilePolicy.group == "root";
            assert sopsKeyFilePolicy.mode == "0400";
            assert sopsGenerationContractData.schemaVersion == 1;
            assert lib.hasPrefix "/nix/store/" sopsGenerationContractData.ciphertext.path;
            assert lib.hasPrefix "/nix/store/" sopsGenerationContractData.sopsManifest;
            assert
              sopsGenerationContractData.ciphertext.sha256
              == builtins.hashFile "sha256" hostConfig.sops.defaultSopsFile;
            pkgs.runCommandLocal "check-sops-policy"
              {
                nativeBuildInputs = [
                  pkgs.age
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.diffutils
                  pkgs.git
                  pkgs.gnugrep
                  pkgs.gnused
                  pkgs.jq
                  pkgs.sops
                  pkgs.util-linux
                  pkgs.yq
                ];
              }
              ''
                set -euo pipefail

                yq -r '.creation_rules[].key_groups[].age[]' ${self}/secrets/.sops.yaml \
                  | sort > configured-recipients
                yq -r '[.keys.recovery] + [.keys.hosts[]] | .[]' ${self}/secrets/.sops.yaml \
                  | sort > named-recipients
                yq -r '.sops.age[].recipient' ${self}/secrets/secrets.yaml \
                  | sort > encrypted-recipients
                test -s configured-recipients
                test -s named-recipients
                test -s encrypted-recipients
                diff --brief configured-recipients encrypted-recipients
                diff --brief configured-recipients named-recipients
                test "$(wc -l < configured-recipients)" -eq "$(sort -u configured-recipients | wc -l)"
                test "$(wc -l < encrypted-recipients)" -eq "$(sort -u encrypted-recipients | wc -l)"

                for backend in kms gcp_kms azure_kv hc_vault pgp; do
                  yq --exit-status ".sops.$backend // [] | length == 0" \
                    ${self}/secrets/secrets.yaml > /dev/null
                done
                contract_ciphertext=$(jq -er '.ciphertext.path' ${sopsGenerationContract})
                contract_hash=$(jq -er '.ciphertext.sha256' ${sopsGenerationContract})
                test "$(sha256sum "$contract_ciphertext" | cut -d ' ' -f 1)" = "$contract_hash"
                contract_installer=$(jq -er '.reinstallSecrets' ${sopsGenerationContract})
                sops_manifest=$(sed -n \
                  's|.*sops-install-secrets \(/nix/store/[^ ]*-manifest.json\).*|\1|p' \
                  "$contract_installer")
                test -f "$sops_manifest"
                test "$sops_manifest" = "$(jq -er '.sopsManifest' ${sopsGenerationContract})"
                jq --exit-status \
                  --arg ciphertext "$contract_ciphertext" \
                  --arg ciphertextHash "$contract_hash" '
                    (.secrets | length > 0) and
                    all(.secrets[];
                      .sopsFile == $ciphertext and .sopsFileHash == $ciphertextHash)
                  ' "$sops_manifest" > /dev/null
                production_keyctl=${lib.getExe hostConfig.my.commands.sopsEnroll.productionKeyctl}
                for argument in \
                  '--property=DynamicUser=yes' \
                  '--property=PrivateNetwork=yes' \
                  '--property=ProtectSystem=strict' \
                  '--property=ProtectHome=yes' \
                  '--property=RestrictAddressFamilies=AF_UNIX' \
                  'LoadCredential=age.key:$key'; do
                  grep --fixed-strings -- "$argument" "$production_keyctl" > /dev/null
                done
                production_verifier=${lib.getExe hostConfig.my.commands.sopsEnroll.productionVerifier}
                grep --fixed-strings 'identity=$CREDENTIALS_DIRECTORY/age.key' \
                  "$production_verifier" > /dev/null
                grep --fixed-strings 'SOPS_AGE_KEY_FILE="$identity"' \
                  "$production_verifier" > /dev/null
                bash ${self}/scripts/tests/bootstrap-age-key.sh \
                  ${self}/scripts/bootstrap.sh \
                  ${fakeBootstrapRebuild}
                bash ${self}/scripts/tests/sops-enroll.sh \
                  ${lib.getExe hostConfig.my.commands.sopsEnroll.testPackage} \
                  ${pkgs.age}/bin/age-keygen \
                  ${lib.getExe pkgs.sops} \
                  ${lib.getExe hostConfig.my.commands.sopsEnroll.testKeyctl}

                touch $out
              '';

          sops-verifier-runtime =
            let
              incompatibleGeneration = pkgs.runCommandLocal "sops-vm-incompatible-generation" { } ''
                mkdir -p $out
              '';
            in
            pkgs.testers.runNixOSTest {
              name = "sops-verifier-runtime";
              nodes.machine =
                {
                  config,
                  lib,
                  pkgs,
                  ...
                }:
                let
                  generation = import ./modules/lib/sops-generation-contract.nix {
                    inherit config pkgs;
                  };
                in
                {
                  imports = [ sops-nix.nixosModules.sops ];
                  system.extraDependencies = [ incompatibleGeneration ];
                  environment.systemPackages = [
                    hostConfig.my.commands.sopsEnroll.productionKeyctl
                    pkgs.age
                    pkgs.jq
                    pkgs.sops
                  ];
                  sops = {
                    defaultSopsFile = ./scripts/tests/fixtures/sops-vm-secrets.yaml;
                    age = {
                      keyFile = "/var/lib/sops-nix/key.txt";
                      generateKey = false;
                    };
                    secrets.fixture = { };
                  };
                  system.activationScripts = {
                    installSopsVmKey = {
                      deps = [ "specialfs" ];
                      text = ''
                        install -d -o root -g root -m 0700 /var/lib/sops-nix
                        install -o root -g root -m 0400 \
                          ${./scripts/tests/fixtures/sops-vm-old-key.txt} \
                          /var/lib/sops-nix/key.txt
                      '';
                    };
                    setupSecrets.deps = lib.mkBefore [ "installSopsVmKey" ];
                  };
                  environment.etc."dotfiles/sops-generation.json".source = generation.contract;
                };
              testScript = ''
                machine.start()
                machine.wait_for_unit("multi-user.target")
                machine.succeed("grep -Fx 'vm-secret' /run/secrets/fixture")
                machine.succeed(
                  "nix-env --profile /nix/var/nix/profiles/system"
                  " --set \"$(realpath /run/current-system)\""
                )
                machine.succeed(
                  "test \"$(realpath /run/current-system)\" = "
                  "\"$(realpath /nix/var/nix/profiles/system)\""
                )
                machine.succeed(
                  "nix-env --profile /nix/var/nix/profiles/system"
                  " --set ${incompatibleGeneration}"
                )
                machine.succeed(r"""
                  for link in /nix/var/nix/profiles/system-[0-9]*-link; do
                    if [ "$(realpath -e "$link")" = "${incompatibleGeneration}" ]; then
                      printf '%s\n' "$link" > /tmp/sops-incompatible-generation-link
                    fi
                  done
                  test -s /tmp/sops-incompatible-generation-link
                """)
                machine.succeed(
                  "nix-env --profile /nix/var/nix/profiles/system"
                  " --set \"$(realpath /run/current-system)\""
                )
                machine.succeed(
                  "test \"$(realpath /run/current-system)\" = "
                  "\"$(realpath /nix/var/nix/profiles/system)\""
                )
                machine.succeed(
                  "install -o root -g root -m 0400 "
                  "${./scripts/tests/fixtures/sops-vm-new-key.txt} /var/lib/sops-nix/key.next"
                )
                machine.succeed(r"""
                  old_recipient=$(age-keygen -y /var/lib/sops-nix/key.txt)
                  new_recipient=$(age-keygen -y /var/lib/sops-nix/key.next)
                  jq -n \
                    --arg previousRecipient "$old_recipient" \
                    --arg nextRecipient "$new_recipient" '{
                    version: 1,
                    transactionId: "0123456789abcdef0123456789abcdef",
                    state: "staged",
                    hostId: null,
                    previousRecipient: $previousRecipient,
                    nextRecipient: $nextRecipient,
                    oldConfigHash: null,
                    oldSecretsHash: null,
                    newConfigHash: null,
                    newSecretsHash: null,
                    historyToClose: null,
                    closedGenerations: [],
                    candidateSystem: null,
                    startedAt: "1970-01-01T00:00:00Z"
                  }' > /var/lib/sops-nix/enrollment.json
                  chmod 0600 /var/lib/sops-nix/enrollment.json
                """)
                machine.succeed(
                  "dotfiles-sops-keyctl verify-next 0123456789abcdef0123456789abcdef"
                  " < ${./scripts/tests/fixtures/sops-vm-secrets.yaml}"
                )
                machine.succeed(
                  "dotfiles-sops-keyctl verify-previous 0123456789abcdef0123456789abcdef"
                  " < ${./scripts/tests/fixtures/sops-vm-secrets.yaml}"
                )
                machine.succeed(r"""
                  new_hash=$(sha256sum ${./scripts/tests/fixtures/sops-vm-secrets.yaml} | cut -d ' ' -f 1)
                  jq -n --arg newSecretsHash "$new_hash" '{
                    hostId: "vm-nixos",
                    oldConfigHash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    oldSecretsHash: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                    newConfigHash: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
                    newSecretsHash: $newSecretsHash
                  }' | dotfiles-sops-keyctl prepare 0123456789abcdef0123456789abcdef
                """)
                machine.succeed(
                  "dotfiles-sops-keyctl arm-swap 0123456789abcdef0123456789abcdef"
                )
                machine.succeed(
                  "dotfiles-sops-keyctl mark-repo-swapped 0123456789abcdef0123456789abcdef"
                )
                machine.succeed(
                  "dotfiles-sops-keyctl mark-generation-pending 0123456789abcdef0123456789abcdef"
                )
                machine.succeed(
                  "dotfiles-sops-keyctl advance-generation 0123456789abcdef0123456789abcdef"
                  " | jq -e '.ready == true'"
                )
                machine.succeed(
                  "dotfiles-sops-keyctl arm-history-close 0123456789abcdef0123456789abcdef"
                  " | jq -e '.incompatible | length == 1'"
                )
                machine.succeed(
                  "dotfiles-sops-keyctl close-history 0123456789abcdef0123456789abcdef"
                )
                machine.succeed(
                  "test ! -L \"$(cat /tmp/sops-incompatible-generation-link)\""
                )
                machine.succeed(
                  "dotfiles-sops-keyctl promote 0123456789abcdef0123456789abcdef"
                )
                machine.succeed(
                  "dotfiles-sops-keyctl verify-current 0123456789abcdef0123456789abcdef"
                  " < ${./scripts/tests/fixtures/sops-vm-secrets.yaml}"
                )
                machine.succeed("rm /run/secrets/fixture")
                machine.succeed(
                  "dotfiles-sops-keyctl reinstall-current 0123456789abcdef0123456789abcdef"
                )
                machine.succeed("grep -Fx 'vm-secret' /run/secrets/fixture")
                machine.succeed(
                  "dotfiles-sops-keyctl mark-verified 0123456789abcdef0123456789abcdef"
                )
                machine.succeed(
                  "dotfiles-sops-keyctl finalize 0123456789abcdef0123456789abcdef"
                )
                machine.succeed("test ! -e /var/lib/sops-nix/key.next")
                machine.succeed("test ! -e /var/lib/sops-nix/enrollment.json")
                machine.succeed(
                  "jq -e '.state == \"complete\" and .freshEnrollment == false"
                  " and (.closedGenerations | length == 1)'"
                  " /var/lib/sops-nix/enrollment-receipt.json"
                )
                machine.succeed(
                  "dotfiles-sops-keyctl verify-installed"
                  " < ${./scripts/tests/fixtures/sops-vm-secrets.yaml}"
                )
              '';
            };

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
                bash ${self}/scripts/tests/rebuild-routing.sh \
                  ${self}/modules/commands/rebuild \
                  ${pkgs.bash}/bin/bash \
                  ${lib.getExe pkgs.fakeroot} \
                  ${self}/scripts/lib/operation-lock.sh \
                  ${self}/scripts/lib/rebuild-receipt.sh
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
                'Use dotfiles-rebuild for normal changes; use scripts/bootstrap.sh only for initial provisioning.' \
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
                ];
              }
              ''
                bash ${self}/scripts/tests/doctor-runtime.sh \
                  ${self}/modules/commands/doctor \
                  ${pkgs.bash}/bin/bash
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

          development-tool-ownership =
            let
              systemPackageNames = map lib.getName hostConfig.environment.systemPackages;
              homePackageNames = map lib.getName homeConfig.home.packages;
              nixDirenvSource = "${homeConfig.programs.direnv.nix-direnv.package}/share/nix-direnv/direnvrc";
              binaryCaches = import ./modules/nix-caches.nix;
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

          shellcheck = pkgs.runCommandLocal "check-shellcheck" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
            shellcheck --severity=warning \
              ${self}/scripts/*.sh \
              ${self}/scripts/tests/*.sh \
              ${self}/modules/user/git/hooks/*
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

          # 配備対象 config の構文検査、@var@ 込みの template は dummy 値を焼き込んだ derivation を対象にする
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
    };
}
