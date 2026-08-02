{
  helpers,
  pkgs,
  lib,
  self,
  hostConfig,
  hostOptions,
  variantConfig,
  allCheckNames,
  ...
}:

let
  artifacts = hostConfig.my.artifacts;
  artifactSourcesFor =
    format:
    map (artifact: artifact.source) (
      builtins.attrValues (lib.filterAttrs (_: artifact: artifact.format == format) artifacts)
    );
  asArgs = files: lib.concatMapStringsSep " " (f: "${f}") files;

  # artifact を足したとき、この表への追記も強制する
  expectedFormats = {
    "clis/antigravity/mcp" = "json";
    "clis/claude/lsp" = "json";
    "clis/claude/managed-mcp" = "json";
    "clis/claude/managed-settings" = "json";
    "clis/claude/user-settings-seed" = "json";
    "clis/codex/project" = "toml";
    "clis/codex/system" = "toml";
    "clis/codex/user-seed" = "toml";
    "clis/opencode/config" = "json";
    "mcp/memory/config" = "yaml";
    "mcp/searxng/settings-template" = "yaml";
    "telemetry/collector" = "yaml";
  }
  // lib.genAttrs (map (endpoint: endpoint.artifact) (
    builtins.attrValues hostConfig.my.contract.mcp.endpoints
  )) (_: "yaml")
  // lib.optionalAttrs (hostConfig.my.accounts != [ ]) {
    "accounts/gh-hosts" = "yaml";
  };

  homeConfig = hostConfig.home-manager.users.${hostConfig.my.username};
in
{
  # unit の層の file 名。ここが唯一の定義で、検査はここを読む
  # loopback port の占有は host 全体の資源で、単一 unit の不変条件ではない。
  # 宣言を増やさず、既存の contract と container 宣言から全 listener を集める
  # port を宣言しない生 unit は 46 check のどれにも届かない。socat 一本で
  # gateway と同じ port を 0.0.0.0 で取れる。unit を登録制にする
  service-listener-registry =
    let
      contract = hostConfig.my.contract;

      declaredHere = lib.unique (
        lib.concatMap (
          definition:
          lib.optionals (lib.hasPrefix (toString self) (toString definition.file)) (
            builtins.attrNames definition.value
          )
        ) hostOptions.systemd.services.definitionsWithLocations
      );

      # port を持たないと宣言した unit。増えるときは必ずこの表に現れる
      withoutListener = [
        "dotfiles-cli-autoupdate"
        "docker-dotfiles-backends-network"
        "nix-daemon"
        "sonarqube-provision"
      ];

      registered = lib.sort builtins.lessThan (
        lib.unique (
          map (front: front.service) (builtins.attrValues contract.mcp.fronts)
          ++ map (endpoint: endpoint.service) (builtins.attrValues contract.mcp.endpoints)
          ++ [ contract.telemetry.service ]
          ++ map (name: "docker-${name}") (
            builtins.attrNames hostConfig.virtualisation.oci-containers.containers
          )
          ++ withoutListener
        )
      );
    in
    assert lib.assertMsg (lib.sort builtins.lessThan declaredHere == registered) (
      "systemd service is not registered as a listener or as portless: "
      + lib.concatStringsSep " " (
        lib.subtractLists registered declaredHere ++ lib.subtractLists declaredHere registered
      )
    );
    pkgs.runCommandLocal "check-service-listener-registry" { } "touch $out";

  loopback-port-single-owner =
    let
      contract = hostConfig.my.contract;
      inherit (helpers.containerArgv)
        publishedPorts
        ;

      listeners =
        lib.mapAttrsToList (name: front: {
          owner = "mcp-front-${name}";
          inherit (front) port;
        }) contract.mcp.fronts
        ++ lib.mapAttrsToList (id: endpoint: {
          owner = "agentgateway-${id}";
          inherit (endpoint) port;
        }) contract.mcp.endpoints
        ++ lib.concatLists (
          lib.mapAttrsToList (
            id: endpoint:
            lib.mapAttrsToList (_: port: {
              owner = "agentgateway-${id}";
              inherit port;
            }) endpoint.managementPorts
          ) contract.mcp.endpoints
        )
        ++ lib.mapAttrsToList (_: port: {
          owner = contract.telemetry.service;
          inherit port;
        }) contract.telemetry.ports
        ++ map (entry: {
          inherit (entry) owner;
          port = lib.toInt (builtins.elemAt (lib.splitString ":" entry.value) 1);
        }) publishedPorts;

      ownersOf =
        port:
        lib.unique (
          map (listener: listener.owner) (lib.filter (listener: listener.port == port) listeners)
        );
      numbers = lib.unique (map (listener: listener.port) listeners);
      duplicates = lib.filter (port: builtins.length (ownersOf port) > 1) numbers;
    in
    assert listeners != [ ];
    assert lib.assertMsg (duplicates == [ ]) (
      "loopback port is bound by more than one owner: "
      + lib.concatMapStringsSep ", " (
        port: "${toString port} <- " + lib.concatStringsSep " " (ownersOf port)
      ) duplicates
    );
    pkgs.runCommandLocal "check-loopback-port-single-owner" { } "touch $out";

  # option の接頭辞は宣言した unit の名前で決まる。regex ではなく module 系が
  # 持つ宣言位置から判定するので、nested な options.my = { ... } も子 unit も
  # my.contract.<unit> も同じ規則で見る
  # 生成した artifact が登録簿に載り、accounts を空にすると gh-hosts が消える
  artifact-registry =
    assert lib.mapAttrs (_: artifact: artifact.format) artifacts == expectedFormats;
    assert
      lib.mapAttrs (_: artifact: artifact.format) variantConfig.my.artifacts
      == builtins.removeAttrs expectedFormats [ "accounts/gh-hosts" ];
    assert !(builtins.hasAttr "gh-hosts.yml" variantConfig.sops.templates);
    assert
      hostConfig.my.accounts == [ ]
      ||
        hostConfig.sops.templates."gh-hosts.yml".content
        == builtins.readFile artifacts."accounts/gh-hosts".source;
    pkgs.runCommandLocal "check-artifact-registry" { } "touch $out";

  # 各 producer が実配備へ渡す immutable source を形式別に検査する
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
        for f in ${asArgs (artifactSourcesFor "json")}; do
          jq empty "$f"
        done
        for f in ${asArgs (artifactSourcesFor "toml")}; do
          taplo lint "$f"
        done
        for f in ${asArgs (artifactSourcesFor "yaml")}; do
          yq . "$f" > /dev/null
        done
        touch $out
      '';

  option-namespace =
    let
      rootVocabulary = [
        "artifacts"
        "dotfilesDir"
        "homeDir"
        "username"
      ];

      unitOf =
        declaration:
        let
          relative = lib.removePrefix "${self}/" (toString declaration);
        in
        builtins.head (lib.splitString "/" relative);

      # 宣言が自 unit と一致しない option を集める。sub-option を持つ名前空間は
      # declarations を持たないので、配下を辿って宣言位置を集める
      declarationsOf =
        option:
        option.declarations or (lib.concatMap declarationsOf (
          builtins.attrValues (lib.filterAttrs (name: _: !(lib.hasPrefix "_" name)) option)
        ));

      violationsIn =
        prefix: options:
        lib.concatLists (
          lib.mapAttrsToList (
            name: option:
            let
              declaredIn = lib.unique (map unitOf (declarationsOf option));
              # 一つでも別 unit が宣言していれば違反。名前空間を他 unit が
              # 借りて option を足す形を通さない
              matches = lib.all (unit: unit == name) declaredIn;
            in
            if lib.elem name rootVocabulary then
              [ ]
            else if declaredIn == [ ] then
              [ ]
            else if matches then
              [ ]
            else
              [ "${prefix}${name} <- ${lib.concatStringsSep "," declaredIn}" ]
          ) options
        );

      myOptions = lib.filterAttrs (name: _: !(lib.hasPrefix "_" name)) hostOptions.my;
      # my.contract は freeform なので sub-option を持たない。どの unit がどの key を
      # 定義したかは定義位置から引く
      contractViolations = lib.concatMap (
        definition:
        let
          unit = unitOf definition.file;
        in
        map (name: "my.contract.${name} <- ${unit}") (
          builtins.filter (name: name != unit) (builtins.attrNames definition.value)
        )
      ) hostOptions.my.contract.definitionsWithLocations;

      violations =
        violationsIn "my." (builtins.removeAttrs myOptions [ "contract" ]) ++ contractViolations;
    in
    assert violations == [ ];
    pkgs.runCommandLocal "check-option-namespace" { } "touch $out";

  # unit をまたぐ依存は my.contract か、module / checks への注入だけを通す。
  # 他 unit の impl や assets を path で読むと、宣言していない結合になる
  unit-boundary-name-only =
    pkgs.runCommandLocal "check-unit-boundary-name-only" { nativeBuildInputs = [ pkgs.gnugrep ]; }
      ''
        set -euo pipefail

        violations=""
        while IFS= read -r file; do
          owner=''${file#${self}/}
          owner=''${owner%%/*}
          while IFS= read -r target; do
            target=''${target%%/*}
            [ "$target" = "$owner" ] || violations="$violations ''${file#${self}/}->$target"
          done < <(
            grep -ohE '\$\{self\}/[a-z0-9-]+/(impl|assets|package|fixtures)|\.\./[a-z0-9-]+/(impl|assets|package|fixtures)' "$file" \
              | sed -E 's|^\$\{self\}/||; s|^\.\./||' || true
          )
        done < <(find ${self} -name '*.nix' -not -path '*/.git/*')

        if [ -n "$violations" ]; then
          echo "unit reads another unit through a path instead of a contract:$violations" >&2
          exit 1
        fi
        touch $out
      '';

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

        # 判定は flake の collectUnits と同じでなければ、片方だけが歩く unit が出る
        is_unit() {
          [ -f "$1/module.nix" ] || [ -f "$1/package.nix" ] || [ -f "$1/checks.nix" ] ||
            [ -d "$1/impl" ]
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
    # shebang を持つ file は誰かが直接叩く。持たない fragment は
    # writeShellApplication へ埋め込まれ build 時に検査される
    find ${self} -type f -not -path '*/.git/*' -exec \
      sh -c 'head -c 2 "$1" | grep -q "^#!"' _ {} \; -print \
      | xargs shellcheck --severity=warning
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
      binaryCaches = import (self + "/system/assets/nix-caches.nix");
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
