{
  pkgs,
  lib,
  self,
  hostOptions,
  units,
  ...
}:

let
  # 全 consumer の移行後は例外を持たない。空集合も下の AST scan が実入力を
  # 検出したことを確かめるため、gate 自体は vacuous にならない。
  allowedPureHelperImports = { };

  rootUnitNames = lib.unique (
    builtins.filter (name: name != "") (map (unit: lib.head (lib.splitString "/" unit.id)) units)
  );
  commandHelper = ".." + "/commands/impl/mk-command.nix";
  nestedCommandHelper = ".." + "/.." + "/commands/impl/mk-command.nix";
  userSecretHelper = ".." + "/sops/impl/user-secret-file.nix";
  approvedExplicitHelperImports = {
    "accounts/module.nix" = {
      target = userSecretHelper;
      line = "  mkUserSecretFile = import ${userSecretHelper} { inherit username; };";
    };
    "agents/module.nix" = {
      target = commandHelper;
      line = "  mkCommand = import ${commandHelper} { inherit config lib pkgs; };";
    };
    "containers/module.nix" = {
      target = commandHelper;
      line = "  mkCommand = import ${commandHelper} { inherit config lib pkgs; };";
    };
    "containers/sonarqube/module.nix" = {
      target = nestedCommandHelper;
      line = "  mkCommand = import ${nestedCommandHelper} { inherit config lib pkgs; };";
    };
  };

  # path を式で組み立てる file reader は境界を文字列検索から隠せる。
  # 現在必要な動的 operand の source と件数を固定し、追加は明示的な変更にする
  allowedDynamicImports = {
    "flake.nix" = 1;
  };
  allowedDynamicFileReads = {
    "accounts/checks.nix" = 1;
    "accounts/module.nix" = 3;
    "agents/codex/module.nix" = 1;
    "agents/opencode/module.nix" = 1;
    "commands/impl/mk-command.nix" = 1;
    "containers/searxng/module.nix" = 1;
    "gates/impl/exec-tokens.nix" = 1;
  };
in
{
  # unit をまたぐ依存は型付き option と allowlist に固定した pure helper の
  # exact import だけを通す。他 unit の impl や assets を広く読むと、
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
        backendSuffix=$(tr -d '\n' < ${../fixtures/unit-boundary-target.txt})
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

        resolveTargets() {
          local applications=$1 bindings=$2 output=$3
          jq --slurpfile bindings "$bindings" --arg suffix "$backendSuffix" '
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
          ' "$applications" > "$output"
        }

        resolveTargets "$workDir/applications.json" "$workDir/bindings.json" \
          "$workDir/target-applications.json"
        resolveTargets "$workDir/imports.json" "$workDir/bindings.json" \
          "$workDir/target-imports.json"
        resolveTargets "$workDir/read-files.json" "$workDir/bindings.json" \
          "$workDir/target-read-files.json"

        mutationSource="$workDir/unit-boundary-target-applications.nix"
        cp ${../fixtures/unit-boundary-target-applications.txt} "$mutationSource"
        ast-grep run --lang nix --json=compact -p '$F $P' "$mutationSource" \
          > "$workDir/mutation-applications.json"
        ast-grep run --lang nix --json=compact -p 'let $A = $V; in {}' \
          --selector binding "$mutationSource" > "$workDir/mutation-bindings.json"
        resolveTargets "$workDir/mutation-applications.json" "$workDir/mutation-bindings.json" \
          "$workDir/mutation-target-applications.json"
        mutationTargetApplicationCount=$(jq 'length' "$workDir/mutation-target-applications.json")
        mutationDirectOperand="./containers/$backendSuffix"
        mutationDirectTargetApplicationCount=$(jq \
          --arg operand "$mutationDirectOperand" \
          '[
            .[]
            | select(.metaVariables.single.P.text == $operand)
            | select(.range.start.line == 5)
          ] | length' "$workDir/mutation-target-applications.json")
        mutationAliasTargetApplicationCount=$(jq '[
          .[]
          | select(.metaVariables.single.P.text == "target")
          | select(.range.start.line == 6)
        ] | length' "$workDir/mutation-target-applications.json")

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
        if [ "$mutationTargetApplicationCount" -ne 2 ]; then
          violations="$violations target-application-mutation=$mutationTargetApplicationCount/2"
        fi
        if [ "$mutationDirectTargetApplicationCount" -ne 1 ]; then
          violations="$violations target-application-direct-mutation=$mutationDirectTargetApplicationCount/1"
        fi
        if [ "$mutationAliasTargetApplicationCount" -ne 1 ]; then
          violations="$violations target-application-alias-mutation=$mutationAliasTargetApplicationCount/1"
        fi
        if [ "$readerAliasCount" -ne 0 ]; then
          violations="$violations reader-alias-binding=$readerAliasCount"
        fi
        for allowed in ${lib.escapeShellArgs (builtins.attrNames allowedPureHelperImports)}; do
          [ -f "${self}/$allowed" ] || violations="$violations missing-allowlisted-source:$allowed"
        done
        for approved in ${lib.escapeShellArgs (builtins.attrNames approvedExplicitHelperImports)}; do
          [ -f "${self}/$approved" ] || violations="$violations missing-approved-helper-consumer:$approved"
        done

        while IFS= read -r file; do
          relative=''${file#${self}/}
          owner=''${relative%%/*}
          allowedTarget=""
          expectedImport=""
          approvedTarget=""
          approvedImport=""
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
              lib.mapAttrsToList (source: spec: ''
                ${lib.escapeShellArg source})
                  approvedTarget=${lib.escapeShellArg spec.target}
                  approvedImport=${lib.escapeShellArg spec.line}
                  ;;
              '') approvedExplicitHelperImports
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
          targetApplicationCount=$(jq --arg file "$relative" '[
            .[] | select(.file == $file)
          ] | length' "$workDir/target-applications.json")
          if [ -n "$approvedTarget" ]; then
            approvedImportCount=$(printf '%s\n' "$source" | grep -Fxc -- "$approvedImport" || true)
            approvedTargetCount=$(printf '%s\n' "$source" | grep -Fo -- "$approvedTarget" | wc -l || true)
            approvedImportNodeCount=$(jq \
              --arg file "$relative" \
              --arg target "$approvedTarget" \
              '[
                .[]
                | select(.file == $file)
                | select((.metaVariables.single.P.text | gsub("[[:space:]()]"; "")) == $target)
              ] | length' "$workDir/imports.json")
            if [ "$approvedImportCount" -ne 1 ] \
              || [ "$approvedTargetCount" -ne 1 ] \
              || [ "$approvedImportNodeCount" -ne 1 ]; then
              violations="$violations $relative:approved-helper-import=$approvedImportCount,target-reference=$approvedTargetCount,import-node=$approvedImportNodeCount"
            else
              source=''${source/"$approvedTarget"/}
            fi
          fi

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
      ownershipFixture = import ../fixtures/mcp-container-ownership.nix;
      mcpContainerOwnership = import ../impl/mcp-container-ownership.nix { inherit lib; };
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

}
