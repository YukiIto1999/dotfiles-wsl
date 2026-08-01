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
        # マシン固有の値のみ、他は各 unit の option の default
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
                mcp.endpoints.default.port = 9876;
              };
            }).config;

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
          expectedConfigArtifactFormats = {
            "clis/antigravity/mcp" = "json";
            "clis/claude/lsp" = "json";
            "clis/claude/managed-mcp" = "json";
            "clis/claude/managed-settings" = "json";
            "clis/claude/user-settings-seed" = "json";
            "clis/codex/project" = "toml";
            "clis/codex/system" = "toml";
            "clis/codex/user-seed" = "toml";
            "clis/opencode/config" = "json";
            "mcp/agentmemory/config" = "yaml";
            "mcp/searxng/settings-template" = "yaml";
          }
          # endpoint ごとの artifact id は gateway が導く。ここで二つ目の roster を作らない
          // lib.genAttrs (map (endpoint: endpoint.artifact) (
            builtins.attrValues hostConfig.my.contract.mcp.endpoints
          )) (_: "yaml")
          // lib.optionalAttrs (hostConfig.my.accounts != [ ]) {
            "accounts/gh-hosts" = "yaml";
          };
          actualConfigArtifactFormats = lib.mapAttrs (_: artifact: artifact.format) configArtifacts;
          variantConfigArtifactFormats = lib.mapAttrs (
            _: artifact: artifact.format
          ) artifactVariantConfig.my.configArtifacts;
          variantClaudeMcp = artifactVariantConfig.my.configArtifacts."clis/claude/managed-mcp".source;
          jsonConfigs = artifactSourcesFor "json";
          tomlConfigs = artifactSourcesFor "toml";
          yamlConfigs = artifactSourcesFor "yaml";

          asArgs = files: lib.concatMapStringsSep " " (f: "${f}") files;
          checkSet = {
            nixos-toplevel = self.nixosConfigurations.${hostName}.config.system.build.toplevel;

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
                      --arg expected ${lib.escapeShellArg hostConfig.my.contract.mcp.endpoints.default.url} \
                      '.mcpServers.gateway.url == $expected' \
                      ${artifactSource "clis/claude/managed-mcp"} > /dev/null
                    jq --exit-status \
                      --arg expected 'http://localhost:9876/mcp' \
                      '.mcpServers.gateway.url == $expected' \
                      ${variantClaudeMcp} > /dev/null
                    jq --exit-status \
                      --arg expected ${lib.escapeShellArg hostConfig.my.contract.mcp.endpoints.default.url} \
                      '.mcpServers.gateway.serverUrl == $expected' \
                      ${artifactSource "clis/antigravity/mcp"} > /dev/null
                    jq --exit-status \
                      --arg expected ${lib.escapeShellArg hostConfig.my.contract.mcp.endpoints.default.url} \
                      '.mcp.gateway.url == $expected' \
                      ${artifactSource "clis/opencode/config"} > /dev/null
                    test "$(taplo get --output-format json --file-path ${artifactSource "clis/codex/system"} mcp_servers.gateway.url | jq -r .)" = \
                      ${lib.escapeShellArg hostConfig.my.contract.mcp.endpoints.default.url}
                    test "$(taplo get --output-format json --file-path ${artifactSource "clis/codex/user-seed"} model | jq -r .)" = \
                      gpt-5.6-sol
                    test "$(yq -r '.workers[] | select(.name == "iii-http") | .config.port' ${artifactSource "mcp/agentmemory/config"})" = 3111
                    test "$(yq -r '.workers[] | select(.name == "iii-stream") | .config.port' ${artifactSource "mcp/agentmemory/config"})" = 3112
                    test "$(yq -r '.server.port' ${artifactSource "mcp/searxng/settings-template"})" = 8080
                    test "$(yq -r '.valkey.url' ${artifactSource "mcp/searxng/settings-template"})" = valkey://valkey:6379/0
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
