{
  pkgs,
  lib,
  self,
  units,
  ...
}:

let
  allowedPureHelperImports = {
    "capabilities/code-quality/sonarqube/database/module.nix" =
      "../../../../platform/containers/impl/container-backend.nix";
    "capabilities/code-quality/sonarqube/server/module.nix" =
      "../../../../platform/containers/impl/container-backend.nix";
    "capabilities/project-memory/agentmemory/backend/module.nix" =
      "../../../../platform/containers/impl/container-backend.nix";
    "capabilities/web-content/crawl4ai/backend/module.nix" =
      "../../../../platform/containers/impl/container-backend.nix";
    "capabilities/web-discovery/searxng/backend/module.nix" =
      "../../../../platform/containers/impl/container-backend.nix";
  };
  allowedCrossUnitReferences = {
    "capabilities/agent-session/codex/mcp/checks.nix" = [
      "../../../../platform/mcp/package/mk-server.nix"
    ];
    "capabilities/agent-session/codex/mcp/module.nix" = [
      "../../../../platform/mcp/package/mk-server.nix"
    ];
    "capabilities/browser-diagnostics/chrome-devtools/mcp/module.nix" = [
      "../../../../platform/mcp/package/mk-server.nix"
      "../../../../platform/mcp/package/mk-npm.nix"
    ];
    "capabilities/code-quality/sonarqube/database/module.nix" = [
      "../../../../platform/containers/impl/port-bindings.nix"
    ];
    "capabilities/code-quality/sonarqube/mcp/checks.nix" = [
      "../../../../platform/mcp/package/mk-server.nix"
      "../../../../platform/mcp/package/mk-npm.nix"
    ];
    "capabilities/code-quality/sonarqube/mcp/module.nix" = [
      "../../../../platform/mcp/package/mk-server.nix"
      "../../../../platform/mcp/package/mk-npm.nix"
    ];
    "capabilities/code-quality/sonarqube/server/checks.nix" = [
      "../../../../platform/containers/impl/port-bindings.nix"
    ];
    "capabilities/github-resources/github/mcp/module.nix" = [
      "../../../../platform/mcp/package/mk-server.nix"
    ];
    "capabilities/library-documentation/context7/mcp/module.nix" = [
      "../../../../platform/mcp/package/mk-server.nix"
      "../../../../platform/mcp/package/mk-npm.nix"
    ];
    "capabilities/project-memory/agentmemory/mcp/checks.nix" = [
      "../../../../platform/mcp/package/mk-server.nix"
    ];
    "capabilities/project-memory/agentmemory/mcp/module.nix" = [
      "../../../../platform/mcp/package/mk-server.nix"
    ];
    "capabilities/web-content/crawl4ai/mcp/checks.nix" = [
      "../../../../platform/mcp/package/mk-server.nix"
    ];
    "capabilities/web-content/crawl4ai/mcp/module.nix" = [
      "../../../../platform/mcp/package/mk-server.nix"
    ];
    "capabilities/web-discovery/searxng/mcp/checks.nix" = [
      "../../../../platform/mcp/package/mk-server.nix"
      "../../../../platform/mcp/package/mk-npm.nix"
    ];
    "capabilities/web-discovery/searxng/mcp/module.nix" = [
      "../../../../platform/mcp/package/mk-server.nix"
      "../../../../platform/mcp/package/mk-npm.nix"
    ];
    "health/checks/registry.nix" = [ "../../platform/cli/module.nix" ];
  };
  rootUnitNames = lib.unique (
    builtins.filter (name: name != "") (map (unit: lib.head (lib.splitString "/" unit.id)) units)
  );
  commandHelper = ".." + "/platform/cli/impl/mk-command.nix";
  nestedCommandHelper = ".." + "/.." + "/platform/cli/impl/mk-command.nix";
  deeplyNestedCommandHelper = ".." + "/.." + "/.." + "/platform/cli/impl/mk-command.nix";
  deeplyNestedCapabilityCommandHelper =
    ".." + "/.." + "/.." + "/.." + "/platform/cli/impl/mk-command.nix";
  userSecretHelper = ".." + "/secrets/sops/impl/user-secret-file.nix";
  approvedExplicitHelperImports = {
    "identity/module.nix" = {
      target = userSecretHelper;
      line = "  mkUserSecretFile = import ${userSecretHelper} { inherit username; };";
    };
    "agents/module.nix" = {
      target = commandHelper;
      line = "  mkCommand = import ${commandHelper} { inherit config lib pkgs; };";
    };
    "capabilities/code-quality/sonarqube/provisioning/module.nix" = {
      target = deeplyNestedCapabilityCommandHelper;
      line = "  mkCommand = import ${deeplyNestedCapabilityCommandHelper} { inherit config lib pkgs; };";
    };
    "maintenance/cleanup/module.nix" = {
      target = nestedCommandHelper;
      line = "  mkCommand = import ${nestedCommandHelper} { inherit config lib pkgs; };";
    };
    "workstation/activation/rebuild/module.nix" = {
      target = deeplyNestedCommandHelper;
      line = "  mkCommand = import ${deeplyNestedCommandHelper} { inherit config lib pkgs; };";
    };
  };

  # path を式で組み立てる file reader は境界を文字列検索から隠せる。
  # 現在必要な動的 operand の source と件数を固定し、追加は明示的な変更にする
  allowedDynamicImports = {
    "agents/clients/omp/package.nix" = 1;
    "flake.nix" = 1;
  };
  allowedDynamicFileReads = {
    "identity/checks.nix" = 1;
    "identity/module.nix" = 3;
    "agents/clients/codex/module.nix" = 1;
    "agents/clients/omp/module.nix" = 1;
    "agents/clients/opencode/module.nix" = 1;
    "platform/cli/impl/mk-command.nix" = 1;
    "capabilities/web-discovery/searxng/backend/module.nix" = 1;
    "checks/impl/exec-tokens.nix" = 1;
  };
in
{
  # unit をまたぐ依存は型付き option と allowlist に固定した pure helper の
  # exact import だけを通す。他 unit の impl や assets を広く読むと、
  # 宣言していない結合になる
  unit-boundary-name-only =
    assert lib.assertMsg (
      builtins.length (builtins.attrNames allowedPureHelperImports) == 5
    ) "Platform container builder consumers changed without updating the boundary contract";
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
        # Platform container unit は local helper を読む。root 外からの path
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
        mutationDirectOperand="./platform/containers/$backendSuffix"
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
          [ "$relative" = "checks/checks/unit-boundaries.nix" ] && continue
          owner=''${relative%%/*}
          allowedTarget=""
          allowedReferences=""
          approvedTarget=""
          approvedImport=""
          expectedDynamicImports=0
          expectedDynamicFileReads=0
          case "$relative" in
            ${lib.concatStringsSep "\n" (
              lib.mapAttrsToList (source: target: ''
                ${lib.escapeShellArg source})
                  allowedTarget=${lib.escapeShellArg target}
                  ;;
              '') allowedPureHelperImports
            )}
          esac
          case "$relative" in
            ${lib.concatStringsSep "\n" (
              lib.mapAttrsToList (source: targets: ''
                ${lib.escapeShellArg source})
                  allowedReferences=${lib.escapeShellArg (lib.concatStringsSep " " targets)}
                  ;;
              '') allowedCrossUnitReferences
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
            targetCount=$(printf '%s\n' "$source" | grep -Fo -- "$allowedTarget" | wc -l || true)
            if [ "$targetCount" -ne 1 ] \
              || [ "$targetImportCount" -ne 1 ] || [ "$targetFileReadCount" -ne 0 ] \
              || [ "$targetApplicationCount" -ne 1 ]; then
              violations="$violations $relative:target-reference=$targetCount,target-import-node=$targetImportCount,target-read-file-node=$targetFileReadCount,target-application-node=$targetApplicationCount"
            else
              source=''${source/"$allowedTarget"/}
            fi
          elif [[ "$relative" != platform/containers/* ]] \
            && { [ "$targetImportCount" -ne 0 ] || [ "$targetFileReadCount" -ne 0 ] \
              || [ "$targetApplicationCount" -ne 0 ]; }; then
            violations="$violations $relative:target-import-node=$targetImportCount,target-read-file-node=$targetFileReadCount,target-application-node=$targetApplicationCount"
          fi

          for reference in $allowedReferences; do
            referenceCount=$(printf '%s\n' "$source" | grep -Fo -- "$reference" | wc -l || true)
            if [ "$referenceCount" -eq 0 ]; then
              violations="$violations $relative:missing-approved-reference=$reference"
            else
              source=''${source//"$reference"/}
            fi
          done

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

}
