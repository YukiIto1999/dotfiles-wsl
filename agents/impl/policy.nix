{ lib, pkgs }:

let
  tsv = rows: lib.concatStringsSep "\n" (map (cells: lib.concatStringsSep "\t" cells) rows);
  code = value: "`${value}`";
  entries =
    attrs: lib.concatStringsSep " " (lib.mapAttrsToList (name: value: "${name}=${value}") attrs);
in
{
  render =
    {
      template,
      skills,
      subagents,
      capabilities,
      clients,
      dotfilesDir,
      environmentDir,
      standardRoot,
    }:
    let
      capabilityRows = map (
        capability:
        let
          entrySkills = builtins.attrNames (
            lib.filterAttrs (
              _: skill: builtins.elem capability (skill.requiresCapabilities ++ skill.optionalCapabilities)
            ) skills
          );
        in
        [
          (code capability)
          (if entrySkills == [ ] then "なし" else lib.concatMapStringsSep " / " code entrySkills)
        ]
      ) capabilities;
      clientRows = lib.mapAttrsToList (id: client: [
        (code id)
        (code client.subagentMode)
        (code client.skillProjectionMode)
        (code client.lspMode)
        (code client.telemetryMode)
        (code client.projectMemoryMode)
      ]) clients;
      projectMemoryPolicy = lib.optionalString (builtins.elem "project-memory" capabilities) ''
        ### project-memory

        明示的な検索と保存は`memory`を入口にし、同Skillが`project-memory` Capabilityを使う。自動連携の経路は client ごとに異なり、client の能力表が示す。自動連携は同Skillのrecall、検証、保存判断を代替しない。
      '';
      heapDiagnosticsPolicy = lib.optionalString (builtins.elem "heap-diagnostics" capabilities) ''
        heap-diagnosticsの入口は`heap-analysis`とし、local snapshot、比較条件、retainerの証拠から原因を調べる。
        heap artifactをproject-memoryへ送らず、providerの任意host code実行toolや独自接続で分析を代用しない。
      '';
    in
    pkgs.runCommandLocal "agents-policy.md"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.gawk
          pkgs.gnugrep
          pkgs.gnused
          pkgs.yq
        ];
        skillHeader = "目的\tSkill\t起動";
        subagentHeader = "目的\tsubagent";
        capabilityHeader = "Capability\t入口 Skill";
        clientHeader = "client\tsubagent\tSkill 投影\tLSP\tTelemetry\tProject memory";
        skillEntries = entries (lib.mapAttrs (_: skill: "${skill.source}/SKILL.md") skills);
        subagentEntries = entries subagents;
        capabilityRows = tsv capabilityRows;
        clientRows = tsv clientRows;
        inherit
          projectMemoryPolicy
          heapDiagnosticsPolicy
          dotfilesDir
          environmentDir
          standardRoot
          ;
      }
      ''
        set -euo pipefail

        # markdown の組立ては一箇所に閉じる。Nix 側は cell の data だけを TSV で渡す
        render_table() {
          awk -F '\t' '
            NR == 1 {
              printf "|"; for (i = 1; i <= NF; i++) printf " %s |", $i; printf "\n"
              printf "|"; for (i = 1; i <= NF; i++) printf " --- |"; printf "\n"
              next
            }
            { printf "|"; for (i = 1; i <= NF; i++) printf " %s |", $i; printf "\n" }
          '
        }

        # frontmatter の description が表の一 cell に収まらない形なら、壊れた表を作らずに落とす
        description_of() {
          local source=$1 closing description
          test "$(head -n 1 "$source")" = '---'
          closing=$(awk 'NR > 1 && $0 == "---" { print NR; exit }' "$source")
          test -n "$closing"
          sed -n "2,$((closing - 1))p" "$source" > frontmatter.yaml
          description=$(yq -r '.description' frontmatter.yaml)
          if [ -z "$description" ] || [ "$description" = null ]; then
            echo "frontmatter must declare a description: $source" >&2
            exit 1
          fi
          case $description in
            *"|"* | *"$(printf '\t')"* | *"$(printf '\r')"*)
              echo "description must not contain a table separator, tab, or carriage return: $source" >&2
              exit 1
              ;;
          esac
          if [ "$(printf '%s' "$description" | wc -l)" -ne 0 ]; then
            echo "description must be a single line: $source" >&2
            exit 1
          fi
          printf '%s' "$description"
        }

        roster_rows() {
          local header=$1 entry name source
          shift
          printf '%s\n' "$header"
          for entry in "$@"; do
            name=''${entry%%=*}
            source=''${entry#*=}
            if [ "$header" = "$skillHeader" ]; then
              description=$(description_of "$source")
              invocation=$(yq -r '
                if .["user-invocable"] == false and .["disable-model-invocation"] == true then "依存referenceのみ"
                elif .["disable-model-invocation"] == true then "明示呼出しのみ"
                elif .["user-invocable"] == false then "自動のみ"
                else "task一致時" end
              ' frontmatter.yaml)
              if [ "$invocation" = "依存referenceのみ" ]; then
                invocation="$invocation: \`$source\` をRead"
              fi
              printf '%s\t`%s`\t%s\n' "$description" "$name" "$invocation"
            else
              printf '%s\t`%s`\n' "$(description_of "$source")" "$name"
            fi
          done
        }

        skillRoster=$(roster_rows "$skillHeader" $skillEntries | render_table)
        subagentRoster=$(roster_rows "$subagentHeader" $subagentEntries | render_table)
        capabilityRoster=$(printf '%s\n%s\n' "$capabilityHeader" "$capabilityRows" | render_table)
        clientMatrix=$(printf '%s\n%s\n' "$clientHeader" "$clientRows" | render_table)

        substitute ${template} "$out" \
          --subst-var-by skillRoster "$skillRoster" \
          --subst-var-by subagentRoster "$subagentRoster" \
          --subst-var-by capabilityRoster "$capabilityRoster" \
          --subst-var-by clientMatrix "$clientMatrix" \
          --subst-var-by projectMemoryPolicy "$projectMemoryPolicy" \
          --subst-var-by heapDiagnosticsPolicy "$heapDiagnosticsPolicy" \
          --subst-var-by dotfilesDir "$dotfilesDir" \
          --subst-var-by environmentDir "$environmentDir" \
          --subst-var-by standardRoot "$standardRoot"

        # marker が残るのは template と生成器の対応が崩れた状態であり、静かに通さない
        if grep -qE '@[a-zA-Z][a-zA-Z0-9]*@' "$out"; then
          echo 'policy template has an unsubstituted marker' >&2
          exit 1
        fi
      '';
}
