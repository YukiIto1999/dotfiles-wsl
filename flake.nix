{
  description = "NixOS on WSL2";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/7fd4004d0511991fff3a0524856a9be09e28c5f0";

    nixos-wsl.url = "github:nix-community/NixOS-WSL/release-26.05";
    nixos-wsl.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    devenv.url = "github:cachix/devenv/b904dcb51fe48c30db250038241507f60752f222";

    # client binary の供給元。provider 自身の固定 nixpkgs と Bun を使うため、host の nixpkgs へ follows させない
    llm-agents.url = "github:numtide/llm-agents.nix";

    orca = {
      url = "github:stablyai/orca/48fcb4dfa59a0b145779a98f6d92c2890ef58262";
      flake = false;
    };

    mattSkills = {
      url = "github:mattpocock/skills/4588b32ecab9ecc9fc8cc6b6c5e7d675b6004b0d";
      flake = false;
    };

    pstackSkills = {
      url = "github:cursor/plugins/7a583913eb1b8d1a0ee76753d1a2cf072e7b54f9";
      flake = false;
    };

    chromeDevtoolsMcp = {
      url = "tarball+https://registry.npmjs.org/chrome-devtools-mcp/-/chrome-devtools-mcp-1.10.1.tgz";
      flake = false;
    };

    dotnetSkills = {
      url = "github:dotnet/skills/0dcd43ceb15e15a2c45dd54075fbcf3a30632154";
      flake = false;
    };

    explainerSkills = {
      url = "github:mizchi/explainer/578defba7249fde5366689424ed6017f76b5598b";
      flake = false;
    };

    modernWebGuidance = {
      url = "github:GoogleChrome/modern-web-guidance/650eb83619134adb947b1ee8755e6511270bc444";
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
      ...
    }@inputs:
    let
      system = "x86_64-linux";
      inherit (nixpkgs) lib;
      pkgs = nixpkgs.legacyPackages.${system};

      # hosts/ の file 名が host 名と networking.hostName になる
      hostNames = map (lib.removeSuffix ".nix") (
        builtins.attrNames (
          lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".nix" name) (
            builtins.readDir ./hosts
          )
        )
      );
      mkHost =
        hostName:
        lib.nixosSystem {
          specialArgs = { inherit self inputs; };
          modules = [
            { nixpkgs.pkgs = pkgs; }
            nixos-wsl.nixosModules.default
            sops-nix.nixosModules.sops
            home-manager.nixosModules.home-manager
            ./workstation/module.nix
            ./secrets/sops/module.nix
            ./identity/module.nix
            ./toolchain/module.nix
            ./agents/module.nix
            ./knowledge/module.nix
            ./hosts/${hostName}.nix
            { networking.hostName = hostName; }
          ];
        };
      nixosConfigurations = lib.genAttrs hostNames mkHost;
      hostConfig = nixosConfigurations.nixos.config;

      source = self;
      gitHooks = pkgs.linkFarm "git-hooks" (
        lib.mapAttrs (_: lib.getExe) (import ./toolchain/git/package.nix { inherit lib pkgs; })
      );
      runCheck =
        name: nativeBuildInputs: script:
        pkgs.runCommandLocal "check-${name}" { inherit nativeBuildInputs; } ''
          set -euo pipefail
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"
          ${script}
          touch "$out"
        '';
      memoryRuntime = hostConfig.dotfiles.knowledge.memory.override {
        apiUrl = "http://127.0.0.1:18082";
      };
    in
    {
      inherit nixosConfigurations;

      packages.${system}.anode-windows = pkgs.callPackage ./toolchain/package/anode.nix { };

      checks.${system} = {
        format = runCheck "format" [ pkgs.nixfmt-tree ] ''
          cp -r --no-preserve=mode ${source} src
          cd src
          treefmt --ci --no-cache
        '';
        statix = runCheck "statix" [ pkgs.statix ] "statix check --config ${source}/statix.toml ${source}";
        deadnix = runCheck "deadnix" [ pkgs.deadnix ] "deadnix --fail ${source}";
        shellcheck = runCheck "shellcheck" [ pkgs.shellcheck ] ''
          cd ${source}
          shellcheck --shell=bash \
            workstation/memory/reserve-swap.sh \
            workstation/wsl/impl/wslview.sh \
            workstation/wsl/impl/smoke-windows.sh \
            workstation/rebuild/rebuild.sh \
            workstation/doctor/doctor.sh \
            toolchain/git/assets/hooks/* \
            toolchain/git/assets/credential-token-file \
            toolchain/git/fixtures/hooks.sh \
            toolchain/package/aspire-dashboard.sh \
            knowledge/journal/package/entry.sh \
            knowledge/harvest/package/entry.sh
        '';
        # host 構成の評価だけを強制し、system は build しない
        evaluation = pkgs.writeText "nixos-toplevel-drv-path" (
          builtins.unsafeDiscardStringContext hostConfig.system.build.toplevel.drvPath
        );
        git-hooks =
          runCheck "git-hooks"
            [
              pkgs.age
              pkgs.bash
              pkgs.coreutils
              pkgs.git
              pkgs.gnugrep
            ]
            ''
              HOOKS=${gitHooks} \
              GLOBAL_IGNORE=${./toolchain/git/assets/ignore} \
                bash ${./toolchain/git/fixtures/hooks.sh}
            '';
        memory-runtime =
          runCheck "memory-runtime" [ pkgs.git ]
            "${memoryRuntime.python}/bin/python ${./knowledge/memory/runtime_test.py} ${./knowledge/memory/package}";
        journal =
          runCheck "journal"
            [
              pkgs.cmark
              pkgs.git
              pkgs.python3
            ]
            ''
              export PYTHONTZPATH=${pkgs.tzdata}/share/zoneinfo
              python3 ${./knowledge/journal/journal_test.py} ${./knowledge/journal/package}
            '';
        harvest =
          runCheck "harvest" [ pkgs.git ]
            "${pkgs.python3}/bin/python ${./knowledge/harvest/harvest_test.py} ${./knowledge/harvest/package} ${./knowledge/journal/package} ${lib.getExe memoryRuntime}";
      };

      devShells.${system} = {
        default = pkgs.mkShellNoCC {
          packages = with pkgs; [
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
        statechart = pkgs.mkShellNoCC {
          packages = [ pkgs.nodejs_24 ];
          JAVA = lib.getExe' pkgs.jdk "java";
          TLA2TOOLS = pkgs.fetchurl {
            url = "https://github.com/tlaplus/tlaplus/releases/download/v1.7.4/tla2tools.jar";
            hash = "sha256-k2omIGHJFGlN/WaaVDviRXPEXVqg/yCouWsj0B4FDog=";
          };
          PELE_MODULE = "${
            pkgs.runCommand "pele-1.9.0"
              {
                src = pkgs.fetchurl {
                  url = "https://registry.npmjs.org/pele/-/pele-1.9.0.tgz";
                  hash = "sha512-KUmBt7P5JduVKQaP6FKfXiRgH3LBVIKsmdgPJZU7jD3ye6F+Z8fbms+OjivE7rWY09Qx+5X65VKe/9ywKFJ9Sw==";
                };
              }
              ''
                mkdir -p "$out"
                tar -xzf "$src" --strip-components=1 -C "$out"
              ''
          }/dist/pele.js";
        };
      };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
