{ pkgs, ... }:
{
  configuration = [
    (
      {
        pkgs,
        lib,
        hostConfig,
        mkProbeSystem,
        normalMachineModule,
        ...
      }:

      let
        inherit (hostConfig.dotfiles.workstation) username;
        homePackagesOf = configuration: configuration.home-manager.users.${username}.home.packages;
        registry = hostConfig.dotfiles.toolchain.lspRegistry;
        registeredIds = builtins.attrNames registry;
        registeredServers = builtins.attrValues registry;
        toolchain = hostConfig.dotfiles.toolchain.packages;
        hostSelection = lib.sort builtins.lessThan hostConfig.dotfiles.toolchain.enabledLsp;

        lspProbe =
          selection:
          (mkProbeSystem [
            normalMachineModule
            { dotfiles.toolchain.enabledLsp = lib.mkForce selection; }
          ]).config;
        selectedIdsOf = configuration: builtins.attrNames configuration.dotfiles.toolchain.lsp;
        deployedIdsOf =
          configuration:
          builtins.filter (id: lib.elem registry.${id}.package (homePackagesOf configuration)) registeredIds;
        # 評価が拒否されたことだけを観測する
        rejected = value: !(builtins.tryEval value).success;
        artifactSource = configuration: id: configuration.dotfiles.managedArtifacts.${id}.source;
        expectedCommands = selection: builtins.toJSON (map (id: registry.${id}.command) selection);

        subsetSelection = [
          "nix"
          "bash"
        ];
        subsetIds = lib.sort builtins.lessThan subsetSelection;
        emptyProbe = lspProbe [ ];
        subsetProbe = lspProbe subsetSelection;
        unknownProbe = lspProbe [
          "nix"
          "missing-lsp"
        ];
        duplicateProbe = lspProbe [
          "nix"
          "bash"
          "nix"
        ];
        projections = [
          {
            name = "empty";
            selection = [ ];
            probe = emptyProbe;
          }
          {
            name = "subset";
            selection = subsetSelection;
            probe = subsetProbe;
          }
        ];
      in
      {
        # 宣言した command が package に無いと、CLI 側は起動時まで気付かない。採用の有無にかかわらず登録全体を見る
        lsp-command-present =
          assert registeredServers != [ ];
          assert lib.all (
            server: lib.all (extension: lib.hasPrefix "." extension) (builtins.attrNames server.extensions)
          ) registeredServers;
          pkgs.runCommandLocal "check-lsp-command-present" { nativeBuildInputs = [ pkgs.coreutils ]; } (
            lib.concatMapStrings (server: ''
              test -x ${server.package}/bin/${server.command}
            '') registeredServers
            + "touch $out"
          );

        # 採用集合だけが package と各 client の設定へ届き、空集合と部分集合を扱え、未知 ID と重複を拒否する
        lsp-selection =
          assert selectedIdsOf hostConfig == hostSelection;
          assert deployedIdsOf hostConfig == selectedIdsOf hostConfig;
          assert selectedIdsOf emptyProbe == [ ];
          assert deployedIdsOf emptyProbe == [ ];
          assert lib.all (package: lib.elem package (homePackagesOf emptyProbe)) (
            builtins.attrValues toolchain
          );
          assert selectedIdsOf subsetProbe == subsetIds;
          assert deployedIdsOf subsetProbe == selectedIdsOf subsetProbe;
          assert subsetProbe.dotfiles.toolchain.lsp == lib.getAttrs subsetSelection registry;
          assert builtins.attrNames subsetProbe.dotfiles.toolchain.lspRegistry == registeredIds;
          assert rejected (selectedIdsOf unknownProbe);
          assert rejected (builtins.length (homePackagesOf unknownProbe));
          assert rejected (selectedIdsOf duplicateProbe);
          assert rejected (builtins.length (homePackagesOf duplicateProbe));
          pkgs.runCommandLocal "check-lsp-selection" { nativeBuildInputs = [ pkgs.jq ]; } ''
            set -euo pipefail

            # 各 client が読む形式の中で、採用した server の command だけが残ることを見る
            expect_commands() {
              local label=$1 expected=$2 filter=$3 file=$4
              if ! jq --exit-status --argjson expected "$expected" \
                "([$filter] | sort) == (\$expected | sort)" "$file" > /dev/null; then
                echo "$label did not project exactly $expected:" >&2
                jq -c "[$filter]" "$file" >&2
                exit 1
              fi
            }

            project() {
              local label=$1 expected=$2 claudeSettings=$3 ompLsp=$4 opencodeConfig=$5 marketplace
              marketplace=$(jq -r '.extraKnownMarketplaces.dotfiles.source.path' "$claudeSettings")
              expect_commands "$label/claude" "$expected" '.[].command' "$marketplace/lsp/.lsp.json"
              expect_commands "$label/omp" "$expected" '.[].command' "$ompLsp"
              expect_commands "$label/opencode" "$expected" '.lsp[].command[0]' "$opencodeConfig"
            }

            ${lib.concatMapStrings (projection: ''
              project ${lib.escapeShellArg projection.name} \
                ${lib.escapeShellArg (expectedCommands projection.selection)} \
                ${artifactSource projection.probe "agents/claude/managed-settings"} \
                ${artifactSource projection.probe "agents/omp/lsp"} \
                ${artifactSource projection.probe "agents/opencode/config"}
            '') projections}
            touch $out
          '';

        # 上流 release の binary は同梱 library を欠くと build は通って実行時に落ちる
        toolchain-binary-runs =
          pkgs.runCommandLocal "check-toolchain-binary-runs" { nativeBuildInputs = [ pkgs.coreutils ]; }
            ''
              set -euo pipefail

              printf '%s\n' 'semantic search needle' > zg-fixture
              ${lib.getExe toolchain.zvec-grep} query --rg -n -F 'semantic search needle' zg-fixture > zg-exact
              grep -Fq 'semantic search needle' zg-exact
              touch $out
            '';

      }
    )
  ];
  source = [
    {
      git-commit-message-contract =
        pkgs.runCommandLocal "check-git-commit-message-contract"
          {
            nativeBuildInputs = with pkgs; [
              bash
              coreutils
              gnugrep
            ];
          }
          ''
            set -euo pipefail

            hook=${./git/assets/hooks/commit-msg}

            expect_accept() {
              local name="$1"
              shift
              printf '%s\n' "$@" > "$name"
              if ! bash "$hook" "$name" > "$name.stdout" 2> "$name.stderr"; then
                echo "commit-msg rejected valid fixture: $name" >&2
                cat "$name.stderr" >&2
                exit 1
              fi
            }

            expect_reject() {
              local name="$1"
              shift
              printf '%s\n' "$@" > "$name"
              if bash "$hook" "$name" > "$name.stdout" 2> "$name.stderr"; then
                echo "commit-msg accepted invalid fixture: $name" >&2
                exit 1
              fi
            }

            expect_attribution() {
              expect_reject "$@"
              if ! grep -q '^AI attribution: ' "$1.stderr"; then
                echo "commit-msg rejected $1 without reporting AI attribution" >&2
                cat "$1.stderr" >&2
                exit 1
              fi
            }

            accept_each() {
              local prefix="$1" index=0 subject
              shift
              for subject in "$@"; do
                index=$((index + 1))
                expect_accept "$prefix-$index" "$subject"
              done
            }

            reject_each() {
              local prefix="$1" index=0 subject
              shift
              for subject in "$@"; do
                index=$((index + 1))
                expect_reject "$prefix-$index" "$subject"
              done
            }

            for type in feat fix refactor docs test build ci chore style perf revert; do
              expect_accept "valid-$type" "$type: 日本語の要約"
            done
            expect_accept comments "fix: 日本語の要約" "# Git が追加するコメント"
            expect_accept tailwind "docs: Created with Tailwind の例の修正"
            expect_accept non-attribution "fix: Generated by maintainer の表記の修正"
            expect_accept samurai "fix: Samurai により生成する処理の修正"
            accept_each noun-ending \
              "fix: 設定の扱い" \
              "docs: 型の違い" \
              "docs: 手順のまとめ" \
              "refactor: 検査の見直し" \
              "feat: port の割り当て" \
              "fix: 起動順序の修正" \
              "feat: 一覧の絞り込み・件数の表示" \
              "feat: 検査の追加（段階1）" \
              "fix: 競合の防止 (#12)"

            japanese_limit="fix: "
            for _ in $(seq 1 45); do
              japanese_limit="''${japanese_limit}あ"
            done
            printf '%s\n' "$japanese_limit" > japanese-limit
            if ! LC_ALL=C bash "$hook" japanese-limit > japanese-limit.stdout 2> japanese-limit.stderr; then
              echo "commit-msg counted UTF-8 bytes instead of characters" >&2
              cat japanese-limit.stderr >&2
              exit 1
            fi

            expect_reject arbitrary "日本語の要約"
            expect_attribution attribution "fix: この commit は Codex により生成"
            expect_attribution attribution-period "fix: この commit は Codex により生成。"
            expect_attribution attribution-passive "fix: この commit は OpenAI により作成された。"
            expect_attribution attribution-exclamation "fix: この commit は AI によって執筆！"
            expect_attribution attribution-polite "fix: この commit は Codex により生成済みです"
            expect_attribution attribution-no-space "fix: この commit は Codexにより生成"
            expect_attribution attribution-generic-no-space "fix: この commit は AIにより生成"
            expect_attribution attribution-multiple-spaces "fix: Generated  by Codex の帰属"
            expect_attribution attribution-tab $'fix: Generated\tby Codex の帰属'
            expect_attribution openai-attribution "fix: この commit は OpenAI により生成"
            expect_reject scope "fix(agents): 日本語の要約"
            expect_reject tab $'fix:\t日本語の要約'
            expect_reject body "fix: 日本語の要約" "" "理由を本文に書く"
            expect_reject breaking "feat!: 日本語の要約"
            expect_reject english "fix: update README"
            expect_reject unknown-type "release: 日本語の要約"
            expect_reject over-limit "''${japanese_limit}あ"
            expect_reject touten "feat: 一覧の絞り込み、件数の表示"
            expect_reject kuten "fix: 起動順序の修正。"
            reject_each predicate-ending \
              "feat: 既定を無効にする" \
              "fix: 設定を直す" \
              "docs: 手順を書く" \
              "fix: 競合を防ぐ" \
              "feat: 型を組む" \
              "fix: 経路を選ぶ" \
              "fix: 検査が通らぬ" \
              "fix: 型を持つ" \
              "fix: 型を使う" \
              "fix: 設定を直した" \
              "fix: 経路を選んだ" \
              "fix: 起動を止めない" \
              "fix: 型の不一致は無い" \
              "fix: 既定値が正しい" \
              "feat: 型を揃えたい" \
              "feat: 検査を足す（段階1）" \
              "fix: 競合を防ぐ (#12)"
            reject_each particle-ending \
              "feat: 既定を無効に" \
              "docs: 記録を現在地へ" \
              "fix: 設定の既定を" \
              "fix: 起動の検査で" \
              "fix: 型の既定が" \
              "fix: 型の既定は"

            touch "$out"
          '';

      git-pre-commit-leak-contract =
        pkgs.runCommandLocal "check-git-pre-commit-leak-contract"
          {
            nativeBuildInputs = with pkgs; [
              bash
              coreutils
              git
              gnugrep
            ];
          }
          ''
            set -euo pipefail

            hook=${./git/assets/hooks/pre-commit}
            export HOME=$PWD/home GIT_CONFIG_NOSYSTEM=1
            mkdir -p "$HOME" repo
            cd repo
            git init -q

            token="ghp_$(printf 'a%.0s' {1..36})"
            for name in 'plain.txt' '日本語の名前.txt' 'space name.txt' '-dash.txt'; do
              printf '%s\n' "$token" > "./$name"
              git add -- "./$name"
              if bash "$hook" 2> stderr; then
                echo "pre-commit accepted a secret in: $name" >&2
                exit 1
              fi
              grep -Fq -- "$name" stderr
              git rm -q --cached -- "./$name"
              rm -- "./$name"
            done

            printf 'no secret\n' > '日本語の名前.txt'
            git add -- '日本語の名前.txt'
            bash "$hook"

            touch "$out"
          '';
    }
  ];
}
