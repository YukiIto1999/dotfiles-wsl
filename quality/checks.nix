{
  pkgs,
  lib,
  self,
  hostConfig,
  allCheckNames,
  ...
}:

let
  homeConfig = hostConfig.home-manager.users.${hostConfig.my.username};
in
{
  # unit の層の file 名。ここが唯一の定義で、検査はここを読む
  structure-layer-names =
    pkgs.runCommandLocal "check-structure-layer-names"
      {
        layerNames = [
          "module.nix"
          "package.nix"
          "checks.nix"
          "impl"
          "assets"
          "package"
          "tests"
          "fixtures"
        ];
      }
      ''
        set -euo pipefail

        is_unit() {
          [ -f "$1/module.nix" ] || [ -f "$1/package.nix" ] || [ -d "$1/impl" ]
        }

        violations=""
        while IFS= read -r unit; do
          for entry in "$unit"/*; do
            name=$(basename "$entry")
            case " $layerNames " in
              *" $name "*) continue ;;
            esac
            if [ -d "$entry" ] && is_unit "$entry"; then
              continue
            fi
            violations="$violations ''${unit#${self}/}/$name"
          done
        done < <(find ${self} -type d -not -path '*/.git/*' | while IFS= read -r dir; do
          if is_unit "$dir"; then printf '%s\n' "$dir"; fi
        done)

        if [ -n "$violations" ]; then
          echo "unit contains an entry outside the layer name set:$violations" >&2
          exit 1
        fi
        touch $out
      '';

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

        undocumented=""
        for name in $checkNames; do
          grep -qF "\`$name\`" "$list" || undocumented="$undocumented $name"
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
      ${self}/*/tests/*.sh \
      ${self}/git/assets/hooks/*
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
      binaryCaches = import (self + "/modules/nix-caches.nix");
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
