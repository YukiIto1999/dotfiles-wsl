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
          # bootstrap が最初の rebuild 前、system closure が無い状態から呼ぶ
          dotfiles-install-clis = hostConfig.my.commands.installClis;
        };

      checks.${system} =
        let
          hostConfig = self.nixosConfigurations.${hostName}.config;
          inherit (self.nixosConfigurations.${hostName}) pkgs;
          inherit (pkgs) lib;

          agentmemoryTemplate = hostConfig.sops.templates."agentmemory.env";
          agentmemoryEnvironmentFiles =
            hostConfig.virtualisation.oci-containers.containers.agentmemory.environmentFiles;
          agentmemoryApiKeyLine = "OPENAI_API_KEY=${hostConfig.sops.placeholder."opencode/go_api_key"}";
          agentmemoryTemplateFile = pkgs.writeText "agentmemory.env" agentmemoryTemplate.content;
          codexSystemConfig = hostConfig.environment.etc."codex/config.toml".source;
          codexProjectHomePath = "${lib.removePrefix "${hostConfig.my.homeDir}/" hostConfig.my.dotfilesDir}/.codex/config.toml";
          codexProjectConfig =
            hostConfig.home-manager.users.${hostConfig.my.username}.home.file.${codexProjectHomePath}.source;
          codexSeedConfig = pkgs.replaceVars ./modules/clis/codex/config.toml {
            codexModel = "dummy-model";
          };
          codexWritableRoot = "${hostConfig.my.dotfilesDir}/.git";
          sopsKeyFile = "/var/lib/sops-nix/key.txt";
          sopsKeyDirectoryPolicy = hostConfig.systemd.tmpfiles.settings."sops-key"."/var/lib/sops-nix".d;
          sopsKeyFilePolicy = hostConfig.systemd.tmpfiles.settings."sops-key"."/var/lib/sops-nix/key.txt".z;

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

          nixfmt = pkgs.runCommandLocal "check-nixfmt" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
            find ${self} -name '*.nix' -print0 | xargs -0 nixfmt --check
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
