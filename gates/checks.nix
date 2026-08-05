{
  helpers,
  pkgs,
  lib,
  self,
  hostConfig,
  hostOptions,
  units,
  allCheckNames,
  ...
}:

let
  # 根 unit の名前。data 用の directory は unit ではないので対象にしない
  rootUnitNames = lib.unique (
    builtins.filter (name: name != "") (map (unit: lib.head (lib.splitString "/" unit.id)) units)
  );

  # 全 consumer の移行後は例外を持たない。空集合も下の AST scan が実入力を
  # 検出したことを確かめるため、gate 自体は vacuous にならない。
  allowedPureHelperImports = { };

  forbiddenOwnership = [
    "mcp/memory/package/engine"
    "mcp/memory/assets/engine-config.yaml"
    "mcp/searxng/assets/settings.yml"
  ];

  # path を式で組み立てる file reader は境界を文字列検索から隠せる。
  # 現在必要な動的 operand の source と件数を固定し、追加は明示的な変更にする
  allowedDynamicImports = {
    "flake.nix" = 1;
  };
  allowedDynamicFileReads = {
    "accounts/module.nix" = 3;
    "artifacts/checks.nix" = 1;
    "clis/codex/module.nix" = 1;
    "clis/opencode/module.nix" = 2;
    "commands/module.nix" = 1;
    "containers/searxng/module.nix" = 1;
    "gates/impl/exec-tokens.nix" = 1;
  };

  homeConfig = hostConfig.home-manager.users.${hostConfig.my.username};
in
{
  structure-responsibility-roots =
    let
      expectedSonarqubeUnits = [
        "containers/sonarqube"
        "mcp/sonarqube"
      ];
      actualSonarqubeUnits = lib.sort builtins.lessThan (
        map (unit: unit.id) (builtins.filter (unit: builtins.baseNameOf unit.path == "sonarqube") units)
      );
      legacyPath = "toolchain/" + "sonarqube";
      legacyPathExists = builtins.pathExists (self + "/${legacyPath}");
    in
    assert lib.assertMsg (
      actualSonarqubeUnits == expectedSonarqubeUnits && !legacyPathExists
    ) "${legacyPath} must be split into containers/sonarqube and mcp/sonarqube";
    pkgs.runCommandLocal "check-structure-responsibility-roots" { } "touch $out";

  unit-module-marker =
    let
      unitTree = import ./fixtures/unit-tree.nix;
      fixtureCollectUnits = import ./impl/collect-units.nix {
        inherit lib;
        inherit (unitTree) readDir;
      };
      fixtureActual = map (unit: unit.id) (fixtureCollectUnits unitTree.root);
    in
    assert lib.assertMsg (fixtureActual == unitTree.expectedIds) (
      "unit collector fixture mismatch: actual=${builtins.toJSON fixtureActual} "
      + "expected=${builtins.toJSON unitTree.expectedIds}"
    );
    pkgs.runCommandLocal "check-unit-module-marker"
      {
        nativeBuildInputs = [
          pkgs.diffutils
          pkgs.findutils
        ];
      }
      ''
        set -euo pipefail

        printf '%s\n' ${lib.escapeShellArgs (map (unit: unit.id) units)} | sort > actual
        find ${self} -type f -name module.nix -printf '%h\n' \
          | while IFS= read -r directory; do
            printf '%s\n' "''${directory#${self}/}"
          done \
          | sort > expected

        diff -u expected actual
        touch $out
      '';

  runtime-identity =
    let
      expected = builtins.fromJSON (builtins.readFile ./fixtures/runtime-identities.json);
      containers = hostConfig.virtualisation.oci-containers.containers;
      containerValues = builtins.attrValues containers;
      gatewayEndpoint = hostConfig.dotfiles.mcp.gateway;

      containerNetworks = lib.unique (
        lib.sort builtins.lessThan (
          map (lib.removePrefix "--network=") (
            lib.concatMap (
              container: builtins.filter (lib.hasPrefix "--network=") container.extraOptions
            ) containerValues
          )
        )
      );

      persistentPaths = lib.unique (
        lib.sort builtins.lessThan (
          lib.concatMap (
            container:
            builtins.filter (lib.hasPrefix "/var/lib/") (
              map (volume: lib.head (lib.splitString ":" volume)) container.volumes
            )
          ) containerValues
        )
      );

      actual =
        assert lib.assertMsg (
          builtins.length containerNetworks == 1
        ) "runtime identity requires one container network: actual=${builtins.toJSON containerNetworks}";
        {
          mcpTargets = lib.mapAttrs (_: target: target.port) hostConfig.dotfiles.mcp.targets;
          gateway = {
            inherit (gatewayEndpoint) id port service;
          };
          containers = lib.sort builtins.lessThan (builtins.attrNames containers);
          containerNetwork = lib.head containerNetworks;
          secrets = lib.sort builtins.lessThan (builtins.attrNames hostConfig.sops.secrets);
          inherit persistentPaths;
        };
    in
    assert lib.assertMsg (actual == expected) (
      "runtime identity mismatch: expected=${builtins.toJSON expected} "
      + "actual=${builtins.toJSON actual}"
    );
    pkgs.runCommandLocal "check-runtime-identity" { } "touch $out";

  # 誰も読まない契約は、宣言だけが残って中身が腐る。実際に images の契約が
  # 存在しない path を指したまま残っていた
  contract-has-reader =
    let
      ownerOf = lib.listToAttrs (
        lib.concatMap (
          definition:
          let
            unit = lib.head (lib.splitString "/" (lib.removePrefix "${self}/" (toString definition.file)));
          in
          map (name: lib.nameValuePair name unit) (builtins.attrNames definition.value)
        ) hostOptions.my.contract.definitionsWithLocations
      );
    in
    pkgs.runCommandLocal "check-contract-has-reader" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
      set -euo pipefail

      unread=""
      ${lib.concatMapStrings (name: ''
        readers=$(grep -rlF 'contract.${name}' ${self} --include='*.nix'           | grep -v '^${self}/${ownerOf.${name}}/' || true)
        [ -n "$readers" ] || unread="$unread ${name}"
      '') (builtins.attrNames ownerOf)}

      if [ -n "$unread" ]; then
        echo "contract has no reader outside its unit:$unread" >&2
        exit 1
      fi
      touch $out
    '';

  # 登録簿が空になると、それを走査する検査は全て緑のまま何も見なくなる。
  # 個々の検査に非空の assert を書き足すのではなく、登録簿の側で禁じる
  registries-non-empty =
    let
      walk =
        path: opts:
        lib.concatLists (
          lib.mapAttrsToList (
            name: value:
            let
              here = path ++ [ name ];
            in
            if !(lib.isAttrs value) then
              [ ]
            else if value ? _type && value._type == "option" then
              lib.optional (
                lib.hasPrefix "attribute set of" (value.type.description or "")
                && lib.attrByPath here { } hostConfig == { }
              ) (lib.concatStringsSep "." here)
            else
              walk here value
          ) opts
        );

      empty = walk [ "my" ] hostOptions.my;
    in
    assert empty == [ ];
    pkgs.runCommandLocal "check-registries-non-empty" { } "touch $out";

  # unit の層の file 名。ここが唯一の定義で、検査はここを読む
  # loopback port の占有は host 全体の資源で、単一 unit の不変条件ではない。
  # 宣言を増やさず、既存の contract と container 宣言から全 listener を集める
  # port を宣言しない生 unit は他のどの check にも届かない。socat 一本で
  # gateway と同じ port を 0.0.0.0 で取れる。unit を登録制にする
  service-listener-registry =
    let
      contract = hostConfig.my.contract;
      mcp = hostConfig.dotfiles.mcp;

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
          map (front: front.service) (builtins.attrValues mcp.fronts)
          ++ [ mcp.gateway.service ]
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
      mcp = hostConfig.dotfiles.mcp;
      inherit (helpers.containerArgv)
        publishedPorts
        ;

      listeners =
        lib.mapAttrsToList (name: front: {
          owner = "mcp-front-${name}";
          inherit (front) port;
        }) mcp.fronts
        ++ [
          {
            owner = mcp.gateway.service;
            inherit (mcp.gateway) port;
          }
          {
            owner = mcp.gateway.service;
            port = 15000;
          }
          {
            owner = mcp.gateway.service;
            port = 15020;
          }
          {
            owner = mcp.gateway.service;
            port = 15021;
          }
        ]
        ++ lib.mapAttrsToList (_: port: {
          owner = contract.telemetry.service;
          inherit port;
        }) contract.telemetry.ports
        ++ map (entry: {
          inherit (entry) owner;
          port = lib.toInt (builtins.elemAt (lib.splitString ":" entry.value) 1);
        }) publishedPorts;

      # owner を unique にしてから数えると、同じ owner が同じ port を二度
      # bind する形を見逃す。listener の数で判定する
      listenersOn = port: lib.filter (listener: listener.port == port) listeners;
      numbers = lib.unique (map (listener: listener.port) listeners);
      duplicates = lib.filter (port: builtins.length (listenersOn port) > 1) numbers;
    in
    assert listeners != [ ];
    assert lib.assertMsg (duplicates == [ ]) (
      "loopback port is bound by more than one owner: "
      + lib.concatMapStringsSep ", " (
        port:
        "${toString port} <- "
        + lib.concatStringsSep " " (map (listener: listener.owner) (listenersOn port))
      ) duplicates
    );
    pkgs.runCommandLocal "check-loopback-port-single-owner" { } "touch $out";

  # option の接頭辞は宣言した unit の名前で決まる。regex ではなく module 系が
  # 持つ宣言位置から判定するので、nested な options.my = { ... } も子 unit も
  # my.contract.<unit> も同じ規則で見る
  # 生成した artifact が登録簿に載り、accounts を空にすると gh-hosts が消える
  option-namespace =
    let
      rootVocabulary = [
        "artifacts"
        "dotfilesDir"
        "homeDir"
        "username"
      ];

      # unit 名は path の末端で決まる。先頭 segment で決めると、unit を別の
      # 階層へ移した瞬間に option 名の側が壊れる。末端は全 unit で一意でなければ
      # 別の unit が同じ名前空間を名乗れるので、下で一意性を検査する
      unitOf =
        declaration:
        let
          segments = lib.splitString "/" (lib.removePrefix "${self}/" (toString declaration));
          dirs = lib.take (builtins.length segments - 1) segments;
        in
        if dirs == [ ] then "" else lib.last dirs;

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

      # unit 名が一意でないと、別の unit が同じ my.<name> を名乗れる。
      # clis/codex と mcp/codex のように末端名が衝突する組が既にある
      # 危険なのは名前空間を宣言する unit 同士の衝突だけ。何も宣言しない unit が
      # 末端名を共有しても、名乗る名前空間が無いので害が無い
      declaringUnits = lib.unique (
        map unitOf (
          map (d: d.file) hostOptions.my.contract.definitionsWithLocations
          ++ lib.concatMap declarationsOf (builtins.attrValues myOptions)
        )
      );

      duplicateUnitNames = lib.unique (
        builtins.filter (
          name: lib.count (unit: builtins.baseNameOf unit.path == name) units > 1
        ) declaringUnits
      );

      violations =
        violationsIn "my." (builtins.removeAttrs myOptions [ "contract" ])
        ++ contractViolations
        ++ map (name: "duplicate unit name: ${name}") duplicateUnitNames;
    in
    assert lib.assertMsg (violations == [ ]) (
      "option namespace: " + lib.concatStringsSep " " violations
    );
    pkgs.runCommandLocal "check-option-namespace" { } "touch $out";

  # unit をまたぐ依存は my.contract、module / checks への注入、allowlist に固定した
  # pure helper の exact import だけを通す。他 unit の impl や assets を広く読むと、
  # 宣言していない結合になる
  unit-boundary-name-only =
    assert lib.assertMsg (
      allowedPureHelperImports == { }
    ) "container backend helper allowlist must remain empty";
    pkgs.runCommandLocal "check-unit-boundary-name-only"
      {
        nativeBuildInputs = [
          pkgs.ast-grep
          pkgs.gnugrep
          pkgs.jq
        ];
      }
      ''
        set -euo pipefail

        # 層の名前を数え上げると module.nix や checks.nix への直接参照が漏れる。
        # 根 unit の名前を宣言集合として持ち、そこへ入る path を全部拒む
        roots=${lib.escapeShellArg (lib.concatStringsSep " " rootUnitNames)}
        # container owner は ../impl で local helper を読む。root 外からの旧 path
        # だけを target にすると、allowlist が空になった後の scan が vacuous になる。
        backendSuffix=impl/container-backend.nix
        workDir=$PWD

        # comment や string の断片ではなく、reader と operand を Nix AST から取る。
        # operand が path literal でなければ、source ごとの許可件数と照合する
        (
          cd ${self}
          ast-grep run --lang nix --json=compact -p '$F $P' . --globs '*.nix' > "$workDir/applications.json"
          ast-grep run --lang nix --json=compact -p 'let $A = $V; in {}' \
            --selector binding . --globs '*.nix' > "$workDir/bindings.json"
        )
        jq '[
          .[]
          | select((.metaVariables.single.F.text | gsub("[[:space:]()]"; "")) == "import")
        ]' "$workDir/applications.json" > "$workDir/imports.json"
        jq '[
          .[]
          | select((.metaVariables.single.F.text | gsub("[[:space:]()]"; "")) == "builtins.readFile")
        ]' "$workDir/applications.json" > "$workDir/read-files.json"
        jq --slurpfile bindings "$workDir/bindings.json" --arg suffix "$backendSuffix" '
          def compact: gsub("[[:space:]()+\\\"]"; "");
          def identifier: test("^[A-Za-z_][A-Za-z0-9_\\u0027-]*$");
          def resolves_target($file; $expression; $seen):
            ($expression | compact) as $value
            | if ($value | contains($suffix)) then true
              elif (($expression | identifier) and (($seen | index($expression)) == null)) then
                any($bindings[0][];
                  .file == $file
                  and .metaVariables.single.A.text == $expression
                  and resolves_target(
                    $file;
                    .metaVariables.single.V.text;
                    $seen + [ $expression ]
                  ))
              else false
              end;
          [
            .[]
            | select(resolves_target(.file; .metaVariables.single.P.text; []))
          ]
        ' "$workDir/imports.json" > "$workDir/target-imports.json"
        jq --slurpfile bindings "$workDir/bindings.json" --arg suffix "$backendSuffix" '
          def compact: gsub("[[:space:]()+\\\"]"; "");
          def identifier: test("^[A-Za-z_][A-Za-z0-9_\\u0027-]*$");
          def resolves_target($file; $expression; $seen):
            ($expression | compact) as $value
            | if ($value | contains($suffix)) then true
              elif (($expression | identifier) and (($seen | index($expression)) == null)) then
                any($bindings[0][];
                  .file == $file
                  and .metaVariables.single.A.text == $expression
                  and resolves_target(
                    $file;
                    .metaVariables.single.V.text;
                    $seen + [ $expression ]
                  ))
              else false
              end;
          [
            .[]
            | select(resolves_target(.file; .metaVariables.single.P.text; []))
          ]
        ' "$workDir/read-files.json" > "$workDir/target-read-files.json"

        readerAliasCount=$(jq '[
          .[]
          | .metaVariables.single.V.text
          | gsub("[[:space:]()]"; "")
          | select(. == "import" or . == "builtins.readFile")
        ] | length' "$workDir/bindings.json")
        targetImportTotal=$(jq 'length' "$workDir/target-imports.json")

        violations=""
        if [ "$targetImportTotal" -eq 0 ]; then
          violations="$violations container-backend-import-scan-is-empty"
        fi
        if [ "$readerAliasCount" -ne 0 ]; then
          violations="$violations reader-alias-binding=$readerAliasCount"
        fi
        for allowed in ${lib.escapeShellArgs (builtins.attrNames allowedPureHelperImports)}; do
          [ -f "${self}/$allowed" ] || violations="$violations missing-allowlisted-source:$allowed"
        done

        while IFS= read -r file; do
          relative=''${file#${self}/}
          owner=''${relative%%/*}
          allowedTarget=""
          expectedImport=""
          expectedDynamicImports=0
          expectedDynamicFileReads=0
          case "$relative" in
            ${lib.concatStringsSep "\n" (
              lib.mapAttrsToList (source: target: ''
                ${lib.escapeShellArg source})
                  allowedTarget=${lib.escapeShellArg target}
                  expectedImport=${lib.escapeShellArg "  mkContainerBackend = import ${target} { inherit lib; };"}
                  ;;
              '') allowedPureHelperImports
            )}
          esac

          case "$relative" in
            ${lib.concatStringsSep "\n" (
              lib.mapAttrsToList (source: count: ''
                ${lib.escapeShellArg source}) expectedDynamicImports=${toString count} ;;
              '') allowedDynamicImports
            )}
          esac
          case "$relative" in
            ${lib.concatStringsSep "\n" (
              lib.mapAttrsToList (source: count: ''
                ${lib.escapeShellArg source}) expectedDynamicFileReads=${toString count} ;;
              '') allowedDynamicFileReads
            )}
          esac

          source=$(cat "$file")
          dynamicImportCount=$(jq --arg file "$relative" '[
            .[]
            | select(.file == $file)
            | select(.metaVariables.single.P.text | test("^\\.{1,2}/") | not)
          ] | length' "$workDir/imports.json")
          dynamicFileReadCount=$(jq --arg file "$relative" '[
            .[]
            | select(.file == $file)
            | select(.metaVariables.single.P.text | test("^\\.{1,2}/") | not)
          ] | length' "$workDir/read-files.json")
          targetImportCount=$(jq --arg file "$relative" '[
            .[] | select(.file == $file)
          ] | length' "$workDir/target-imports.json")
          targetFileReadCount=$(jq --arg file "$relative" '[
            .[] | select(.file == $file)
          ] | length' "$workDir/target-read-files.json")
          targetApplicationCount=$(jq --arg file "$relative" --arg suffix "$backendSuffix" '[
            .[]
            # この check の script 自体が target suffix を検査値として持つ
            | select(.file == $file and .file != "gates/checks.nix")
            | .metaVariables.single.P.text
            | gsub("[[:space:]()+\\\"]"; "")
            | select(contains($suffix))
          ] | length' "$workDir/applications.json")

          if [ "$dynamicImportCount" -ne "$expectedDynamicImports" ] \
            || [ "$dynamicFileReadCount" -ne "$expectedDynamicFileReads" ]; then
            violations="$violations $relative:dynamic-import=$dynamicImportCount/$expectedDynamicImports,dynamic-read-file=$dynamicFileReadCount/$expectedDynamicFileReads"
          fi

          if [ -n "$allowedTarget" ]; then
            importCount=$(printf '%s\n' "$source" | grep -Fxc -- "$expectedImport" || true)
            targetCount=$(printf '%s\n' "$source" | grep -Fo -- "$allowedTarget" | wc -l || true)
            if [ "$importCount" -ne 1 ] || [ "$targetCount" -ne 1 ] \
              || [ "$targetImportCount" -ne 1 ] || [ "$targetFileReadCount" -ne 0 ] \
              || [ "$targetApplicationCount" -ne 1 ]; then
              violations="$violations $relative:exact-helper-import=$importCount,target-reference=$targetCount,target-import-node=$targetImportCount,target-read-file-node=$targetFileReadCount,target-application-node=$targetApplicationCount"
            else
              # 件数を先に一つへ固定しているため、許可した target だけを一度除ける
              source=''${source/"$allowedTarget"/}
            fi
          elif [ "$owner" != "containers" ] \
            && { [ "$targetImportCount" -ne 0 ] || [ "$targetFileReadCount" -ne 0 ] \
              || [ "$targetApplicationCount" -ne 0 ]; }; then
            violations="$violations $relative:target-import-node=$targetImportCount,target-read-file-node=$targetFileReadCount,target-application-node=$targetApplicationCount"
          fi

          while IFS= read -r target; do
            target=''${target%%/*}
            [ "$target" = "$owner" ] && continue
            for root in $roots; do
              [ "$target" = "$root" ] || continue
              violations="$violations ''${file#${self}/}->$target"
            done
          done < <(
            printf '%s\n' "$source" \
              | grep -ohE 'self \+ "/[a-z0-9-]+/|\$\{self\}/[a-z0-9-]+/|\.\./[a-z0-9-]+/' \
              | sed -E 's|^self \+ "/||; s|^\$\{self\}/||; s|^\.\./||' || true
          )
        done < <(find ${self} -name '*.nix' -not -path '*/.git/*')

        if [ -n "$violations" ]; then
          echo "unit reads another unit through a path instead of a contract:$violations" >&2
          exit 1
        fi
        touch $out
      '';

  # MCP unit は backend contract の consumer。OCI 配備、secret template、同名
  # backend の secret と service contract を持つと ownership が再び混ざる
  mcp-no-container-ownership =
    let
      ownershipFixture = import ./fixtures/mcp-container-ownership.nix;
      mcpContainerOwnership = import ./impl/mcp-container-ownership.nix { inherit lib; };
      ownersWith =
        resolveUnitOwner: fixtureUnits:
        map (
          case:
          let
            owner = resolveUnitOwner fixtureUnits case.file;
          in
          if owner == null then null else owner.id
        ) ownershipFixture.ownerCases;
      # 列挙順に依存する誤実装を逆順 fixture で落とすための mutation。
      lastMatchUnitOwner =
        fixtureUnits: relativeFile:
        lib.foldl' (
          owner: unit:
          if relativeFile == unit.id || lib.hasPrefix "${unit.id}/" relativeFile then unit else owner
        ) null fixtureUnits;
      fixtureOwners = ownersWith mcpContainerOwnership.resolveUnitOwner ownershipFixture.scan.units;
      lastMatchFixtureOwners = ownersWith lastMatchUnitOwner ownershipFixture.scan.units;
      reverseFixtureOwners = ownersWith mcpContainerOwnership.resolveUnitOwner (
        lib.reverseList ownershipFixture.scan.units
      );
      lastMatchReverseOwners = ownersWith lastMatchUnitOwner (
        lib.reverseList ownershipFixture.scan.units
      );
      expectedFixtureOwners = map (case: case.expected) ownershipFixture.ownerCases;
      fixtureScan = mcpContainerOwnership.scan ownershipFixture.scan;
      emptyFixtureScan = mcpContainerOwnership.scan ownershipFixture.emptyScan;
      unresolvedFixtureScan = mcpContainerOwnership.scan ownershipFixture.unresolvedScan;
      combinedFixtureScan = mcpContainerOwnership.scan ownershipFixture.combinedScan;

      relativeFile = file: lib.removePrefix "${self}/" (toString file);
      relativeDefinitions =
        definitions:
        map (definition: {
          file = relativeFile definition.file;
          inherit (definition) value;
        }) definitions;
      actualScan = mcpContainerOwnership.scan {
        inherit units;
        definitions = {
          ociContainers = relativeDefinitions hostOptions.virtualisation.oci-containers.containers.definitionsWithLocations;
          templates = relativeDefinitions hostOptions.sops.templates.definitionsWithLocations;
          services = relativeDefinitions hostOptions.dotfiles.containers.services.definitionsWithLocations;
          secrets = relativeDefinitions hostOptions.sops.secrets.definitionsWithLocations;
        };
      };

    in
    assert lib.assertMsg (fixtureOwners == expectedFixtureOwners) (
      "MCP ownership resolver fixture mismatch: actual=${builtins.toJSON fixtureOwners} "
      + "expected=${builtins.toJSON expectedFixtureOwners}"
    );
    assert lib.assertMsg (reverseFixtureOwners == expectedFixtureOwners) (
      "MCP ownership resolver reverse fixture mismatch: actual=${builtins.toJSON reverseFixtureOwners} "
      + "expected=${builtins.toJSON expectedFixtureOwners}"
    );
    assert lib.assertMsg (lastMatchFixtureOwners == expectedFixtureOwners) (
      "last-match mutation no longer reproduces the previous passing fixture: "
      + "actual=${builtins.toJSON lastMatchFixtureOwners} "
      + "expected=${builtins.toJSON expectedFixtureOwners}"
    );
    assert lib.assertMsg (
      lastMatchReverseOwners != expectedFixtureOwners
    ) "MCP ownership resolver fixture does not reject a last-match mutation";
    assert lib.assertMsg (fixtureScan == ownershipFixture.expectedScan) (
      "MCP ownership detector fixture mismatch: actual=${builtins.toJSON fixtureScan} "
      + "expected=${builtins.toJSON ownershipFixture.expectedScan}"
    );
    assert lib.assertMsg (emptyFixtureScan == ownershipFixture.expectedEmptyScan) (
      "empty MCP ownership scan fixture mismatch: actual=${builtins.toJSON emptyFixtureScan} "
      + "expected=${builtins.toJSON ownershipFixture.expectedEmptyScan}"
    );
    assert lib.assertMsg (unresolvedFixtureScan == ownershipFixture.expectedUnresolvedScan) (
      "unresolved MCP ownership scan fixture mismatch: "
      + "actual=${builtins.toJSON unresolvedFixtureScan} "
      + "expected=${builtins.toJSON ownershipFixture.expectedUnresolvedScan}"
    );
    assert lib.assertMsg (combinedFixtureScan == ownershipFixture.expectedCombinedScan) (
      "combined MCP ownership scan fixture mismatch: actual=${builtins.toJSON combinedFixtureScan} "
      + "expected=${builtins.toJSON ownershipFixture.expectedCombinedScan}"
    );
    pkgs.runCommandLocal "check-mcp-no-container-ownership"
      {
        inherit (actualScan) diagnosticText;
      }
      ''
        set -euo pipefail

        if [ -n "$diagnosticText" ]; then
          printf '%s\n' "$diagnosticText" >&2
          exit 1
        fi
        touch $out
      '';

  structure-layer-names =
    pkgs.runCommandLocal "check-structure-layer-names"
      {
        unitPaths = map (unit: toString unit.path) units;
        inherit forbiddenOwnership;
        layerNames = [
          "module.nix"
          "package.nix"
          "checks.nix"
          "impl"
          "assets"
          "package"
          "fixtures"
        ];
      }
      ''
        set -euo pipefail

        # unit の一覧は flake の collectUnits が唯一の定義。ここで判定を書き直すと
        # 片方だけが歩く unit が出る
        violations=""
        for path in $forbiddenOwnership; do
          [ ! -e "${self}/$path" ] || violations="$violations $path"
        done
        for unit in $unitPaths; do
          for entry in "$unit"/*; do
            name=$(basename "$entry")
            case " $layerNames " in
              *" $name "*) continue ;;
            esac
            case " $unitPaths " in
              *" $entry "*) continue ;;
            esac
            violations="$violations ''${unit#${self}/}/$name"
          done
        done

        if [ -n "$violations" ]; then
          echo "unit contains an entry outside its layer or ownership set:$violations" >&2
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

        # 文書のどこかに名前があれば通る形だと、制約行と対応していなくても
        # 緑になる。表の最終列だけを対応表として読む
        awk -F '|' '/^\|/ { print $(NF - 1) }' "$list" \
          | grep -o '`[a-z][a-z0-9-]*`' | tr -d '`' | sort -u > documented

        undocumented=""
        for name in $checkNames; do
          grep -qFx "$name" documented || undocumented="$undocumented $name"
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

  # link 先が解決しても、表示名が別の path を名乗っていれば読み手は迷う。
  # 実際に rebuild/module.nix という表示が commands/ 配下へ移った後も残っていた
  docs-path-labels =
    pkgs.runCommandLocal "check-docs-path-labels"
      {
        nativeBuildInputs = with pkgs; [
          coreutils
          gnugrep
          gnused
        ];
      }
      ''
        set -euo pipefail

        missing=""
        while IFS= read -r doc; do
          # 大文字を含む token は NAME のような雛形なので対象にしない
          while IFS= read -r label; do
            [ -e "${self}/$label" ] || missing="$missing ''${doc#${self}/}:$label"
          done < <(
            grep -ohE '`[a-z0-9_.-]+/[a-z0-9_./-]+\.(nix|sh|md|yaml|yml|json|py|ts)`' "$doc" \
              | tr -d '`' | sort -u || true
          )
          # skill や agent の資産は例示の path を含む。対象はこの repository の文書
        done < <(find ${self}/README.md ${self}/docs -name '*.md' -not -path '*/superpowers/*')

        if [ -n "$missing" ]; then
          echo "documentation names a path that does not exist:$missing" >&2
          exit 1
        fi
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
      binaryCaches = hostConfig.my.contract.host.binaryCaches;
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
