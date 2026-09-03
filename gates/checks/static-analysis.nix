{
  pkgs,
  lib,
  self,
  hostConfig,
  ...
}:

let
  homeConfig = hostConfig.home-manager.users.${hostConfig.dotfiles.host.username};
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
    mcpExecutables = lib.mapAttrs (_: target: target.executable) hostConfig.dotfiles.mcp.targets;
    host.wslview = lib.getExe wslviewPackage;
  };
in
{
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

        expected=${../fixtures/generated-shell-roster.json}
        actual=${generatedShellActualFile}

        jq -e '
          (.agentmemoryHooks | length) > 0 and
          (.commands | length) > 0 and
          (.mcpExecutables | length) > 0 and
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

        jq -S '.mcpExecutables' "$expected" > expected-mcp-executables.json
        jq -S '.mcpExecutables | keys' "$actual" > actual-mcp-executables.json
        diff -u expected-mcp-executables.json actual-mcp-executables.json
        while IFS=$'\t' read -r id executable; do
          if ! isGeneratedShell "$executable"; then
            echo "MCP executable is not a generated shell wrapper: $id" >&2
            exit 1
          fi
          lintGenerated "$executable"
        done < <(jq -r '.mcpExecutables | to_entries[] | [.key, .value] | @tsv' "$actual")

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
