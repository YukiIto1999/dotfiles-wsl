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
          # 初回 system closure の前、または current generation の command 更新前に checkout から呼ぶ
          dotfiles-install-clis = hostConfig.my.commands.installClis;
          dotfiles-rebuild = hostConfig.my.commands.rebuild;
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
            pkgs.runCommandLocal "check-sops-policy"
              {
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.yq
                ];
              }
              ''
                set -euo pipefail

                yq -r '.creation_rules[].key_groups[].age[]' ${self}/secrets/.sops.yaml \
                  | sort > configured-recipients
                yq -r '.sops.age[].recipient' ${self}/secrets/secrets.yaml \
                  | sort > encrypted-recipients
                test -s configured-recipients
                test -s encrypted-recipients
                diff --brief configured-recipients encrypted-recipients

                for backend in kms gcp_kms azure_kv hc_vault pgp; do
                  yq --exit-status ".sops.$backend // [] | length == 0" \
                    ${self}/secrets/secrets.yaml > /dev/null
                done
                bash ${self}/scripts/tests/bootstrap-age-key.sh ${self}/scripts/bootstrap.sh

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
                ];
              }
              ''
                bash ${self}/scripts/tests/rebuild-routing.sh \
                  ${self}/modules/commands/rebuild \
                  ${pkgs.bash}/bin/bash \
                  ${lib.getExe pkgs.fakeroot}
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
            pkgs.runCommandLocal "check-doctor-manifest-contract"
              {
                nativeBuildInputs = [ pkgs.jq ];
              }
              ''
                set -euo pipefail

                jq --exit-status \
                  --arg expectedPolicy ${lib.escapeShellArg hostConfig.my.doctor.sopsHomeKeyPolicy} \
                  '.schemaVersion == 2 and .sops.homeKey.policy == $expectedPolicy' \
                  ${doctorManifest} > /dev/null

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
                  'any(.managedFiles[]; .path == $path and .source == $source)' \
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
            treefmt --ci --tree-root ${self}
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
