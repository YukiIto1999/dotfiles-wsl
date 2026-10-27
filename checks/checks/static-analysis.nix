{
  pkgs,
  lib,
  self,
  ...
}:
let
  root = /. + builtins.unsafeDiscardStringContext (toString self);
  nixFiles = lib.fileset.fileFilter (file: file.hasExt "nix") root;
  nixSource = lib.fileset.toSource {
    inherit root;
    fileset = nixFiles;
  };
  statixSource = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.union nixFiles (root + "/statix.toml");
  };
in
{
  configuration = [
    (
      {
        pkgs,
        lib,
        self,
        hostConfig,
        ...
      }:

      let
        homeConfig = hostConfig.home-manager.users.${hostConfig.dotfiles.workstation.username};
        wslviewPackage =
          lib.findSingle (package: lib.getName package == "wslview") (throw "wslview package is missing")
            (throw "multiple wslview packages are installed")
            hostConfig.environment.systemPackages;
        generatedShellActual = {
          projectMemoryHooks = toString hostConfig.dotfiles.capabilities.project-memory.clientIntegrations.hooks;
          commands = lib.mapAttrs (_: package: lib.getExe package) hostConfig.dotfiles.platform.cli.commands;
          mcpExecutables = lib.mapAttrs (
            _: target: target.executable
          ) hostConfig.dotfiles.platform.mcp.targets;
          workstation.wslview = lib.getExe wslviewPackage;
        };
      in
      {

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
                pkgs.findutils
                pkgs.jq
                pkgs.shellcheck
              ];
            }
            ''
              set -euo pipefail

              actual=${generatedShellActualFile}

              jq -e '
                (.projectMemoryHooks | length) > 0 and
                (.commands | length) > 0 and
                (.workstation | length) > 0
              ' "$actual" >/dev/null

              sources=()
              while IFS= read -r -d "" source; do
                sources+=("$source")
              done < <(
                find ${self} -type f -not -path '*/.git/*' -exec \
                  sh -c 'head -c 2 "$1" | grep -q "^#!"' _ {} \; -print0
              )
              test "''${#sources[@]}" -gt 0

              isGeneratedShell() {
                local source=$1 shebang
                test -f "$source"
                shebang=$(head -n 1 "$source")
                case "$shebang" in
                  *'/bash' | *'/sh') return 0 ;;
                  *) return 1 ;;
                esac
              }

              collectGeneratedShell() {
                local source=$1
                isGeneratedShell "$source"
                sources+=("$source")
              }

              find "$(jq -r '.projectMemoryHooks' "$actual")/bin" \
                -maxdepth 1 -type f -o -type l \
                | while IFS= read -r hook; do basename "$hook"; done \
                | sort > actual-hooks
              test -s actual-hooks || {
                echo "project memory hook enumeration is empty" >&2
                exit 1
              }
              while IFS= read -r hook; do
                collectGeneratedShell "$(jq -r '.projectMemoryHooks' "$actual")/bin/$hook"
              done < actual-hooks

              while IFS= read -r command; do
                collectGeneratedShell "$command"
              done < <(jq -r '.commands[]' "$actual")

              collectGeneratedShell "$(jq -r '.workstation.wslview' "$actual")"

              while IFS=$'\t' read -r id executable; do
                if ! isGeneratedShell "$executable"; then
                  echo "MCP executable is not a generated shell wrapper: $id" >&2
                  exit 1
                fi
                collectGeneratedShell "$executable"
              done < <(jq -r '.mcpExecutables | to_entries[] | [.key, .value] | @tsv' "$actual")

              printf '%s\0' "''${sources[@]}" | xargs -0 -r shellcheck --severity=warning

              touch $out
            '';

        development-tool-ownership =
          let
            nixDirenvSource = "${homeConfig.programs.direnv.nix-direnv.package}/share/nix-direnv/direnvrc";
            binaryCaches = hostConfig.dotfiles.workstation.binaryCaches;
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
          assert toString homeConfig.xdg.configFile."direnv/lib/hm-nix-direnv.sh".source == nixDirenvSource;
          assert lib.count (substituter: substituter == devenvCache.substituter) substituters == 1;
          assert lib.count (key: key == devenvCache.publicKey) trustedPublicKeys == 1;
          assert lib.count (substituter: substituter == "https://cache.nixos.org") substituters == 1;
          assert lib.count (lib.hasPrefix "cache.nixos.org-1:") trustedPublicKeys == 1;
          pkgs.runCommandLocal "check-development-tool-ownership" { } ''
            touch $out
          '';
      }
    )
  ];
  source = [
    {
      actionlint = pkgs.runCommandLocal "check-actionlint" { nativeBuildInputs = [ pkgs.actionlint ]; } ''
        workflow_dir=${
          builtins.path {
            path = "${self}/.github";
            name = "github-workflow-source";
          }
        }/workflows
        test -n "$(find "$workflow_dir" -type f \( -name '*.yml' -o -name '*.yaml' \) -print -quit)"
        find "$workflow_dir" -type f \( -name '*.yml' -o -name '*.yaml' \) -exec actionlint {} +
        touch $out
      '';

      deadnix = pkgs.runCommandLocal "check-deadnix" { nativeBuildInputs = [ pkgs.deadnix ]; } ''
        deadnix --fail ${nixSource}
        touch $out
      '';
      statix = pkgs.runCommandLocal "check-statix" { nativeBuildInputs = [ pkgs.statix ]; } ''
        statix check --config ${statixSource} ${statixSource}
        touch $out
      '';

      nixfmt = pkgs.runCommandLocal "check-nixfmt" { nativeBuildInputs = [ pkgs.nixfmt-tree ]; } ''
        cp -r --no-preserve=mode ${nixSource} source
        treefmt --ci --tree-root "$PWD/source"
        touch $out
      '';
    }
  ];
}
