# Agent client の選択と更新

**読み手:** client の試用、交換、更新を行う運用者。
作業中に読む。

## 試用と交換

`agents/clients/<id>/module.nix` が `dotfiles.agents.registry` へ登録する adapter と、host が `dotfiles.agents.enabled` で採用する集合を分ける。
adapter を削除せずに、`profiles/hosts/<host>.nix` で採用する client を選ぶ。
host ごとの override には `lib.mkForce` を使い、共通 profile のリストへ追加するだけの宣言にしない。

OMP だけを使い、自動更新せずに試す場合は、host module の既存宣言を維持して次を加える。

```nix
{ lib, ... }:
{
  dotfiles.agents.enabled = lib.mkForce [ "omp" ];
  dotfiles.agents.automaticUpdates.clients = lib.mkForce [ ];
}
```

Claude Code を追加で試す場合は `enabled` を `[ "omp" "claude" ]` に、Codex へ交換する場合は `[ "codex" ]` に変更する。
自動更新の対象を指定する場合は、同時に `automaticUpdates.clients` を採用済み ID の部分集合へ変更する。
登録だけの client は rules、Skill、subagent、config、launcher、installer manifest、health observation、共通 policy の能力表に含まれない。
client ごとの供給方式は adapter の `install` 宣言に従い、共通の package manager へ置き換えない。

宣言を保存してから、[Rebuild](rebuild.md)の手順で plan の対象を確認し、差分を commit して適用する。
新しい generation の installer manifest と doctor に目的の client だけが現れることを確認してから、installer を実行し、その client の認証と対話起動を行う。

```sh
dotfiles-rebuild --plan
# Rebuild の手順に従って commit と適用を行う
dotfiles-install-agents --print-manifest | jq 'map(.name)'
dotfiles-install-agents
dotfiles-doctor
```

採用から外すと Home Manager と NixOS が管理する設定と launcher は次の適用で外れるが、installer が作成した binary、release tree、認証、会話履歴、初回 seed 後の対話設定は削除しない。
既存 session は停止せず、これらの利用者データを残したまま再採用できる。
不要になった upstream binary と利用者データの削除は、稼働中 session と各 client の uninstall 手順を確認して別途行う。

## 更新方針

採用済みの client を手動更新する場合は、現在の generation の command を使う。

```sh
dotfiles-install-agents
```

checkout の宣言から実行する `nix run .#dotfiles-install-agents` は、flake の reference host である `nixos` の採用集合を使う。
別 host の未適用宣言を使う場合は、その host の installer を指定し、次の例の `tcs-a295` を対象 host ID に置き換える。

```sh
nix run .#nixosConfigurations.tcs-a295.config.dotfiles.platform.cli.commands.installAgents -- --print-manifest
nix run .#nixosConfigurations.tcs-a295.config.dotfiles.platform.cli.commands.installAgents
```

`automaticUpdates.clients` の既定は空であり、空なら自動更新 service、timer、health observation を配備しない。
共通 workstation profile は OMP だけを日次更新の対象にしている。
Claude Code の background updater は managed settings の `DISABLE_AUTOUPDATER=1` で、OpenCode の起動時 updater は配備する config の `autoupdate=false` で無効にし、dotfiles の更新対象とは別の自動更新経路を重ねない。
対応する upstream の設定は [Claude Code の環境変数](https://code.claude.com/docs/en/env-vars)と[OpenCode の更新設定](https://opencode.ai/docs/config/#auto-update)を参照する。
自動更新を採用する場合は必要な client だけをリストへ指定し、起動予定と直近の結果を systemd から確認する。
service の command に `--print-manifest` を渡せば、自動更新の対象だけを表示できる。

```sh
systemctl status dotfiles-agent-autoupdate.timer
systemctl status dotfiles-agent-autoupdate.service
```

手動 installer は採用済みの全 client、自動更新 service は指定した部分集合の installer と version probe を実行する。
一つの client の失敗は他の client の処理を止めず、失敗した client 名だけを終了時に報告する。
Antigravity の bootstrap は既存の binary を更新しないため、導入済みの CLI は `agy update` で更新する。
実行中の session は終了させず、新しい binary は次回起動から使う。

## 宣言と release の確認

installer が受け取る manifest は次の command で表示でき、credential は含まない。

```sh
dotfiles-install-agents --print-manifest | jq .
```

Codex、OpenCode、OMP の管理済み release は client ごとの directory にある。
`current` と visible binary は相対 symlink であり、release 名は取得した asset の SHA-256 digest から決まる。
OMP の asset は archive ではなく単一の実行 file なので、release tree は entrypoint だけを持つ。

```sh
find ~/.local/share/dotfiles/agents -maxdepth 3 -mindepth 2 -print
readlink ~/.local/share/dotfiles/agents/codex/current
readlink ~/.local/bin/codex
readlink ~/.local/share/dotfiles/agents/opencode/current
readlink ~/.local/bin/opencode
readlink ~/.local/share/dotfiles/agents/omp/current
readlink ~/.local/bin/omp
```

GitHub release の取得、digest 照合、archive または raw asset の検査、required path 検査、version probe のどれかが失敗した場合は、新しい `current` へ切り替えない。
publish 中の通常の失敗でも旧 `current` へ rollback する。
所有または identity を確認できない object は削除せず、エラーとして残す。
Claude Code と Antigravity の配置と rollback は upstream installer の責務である。

`SIGKILL`、電源断、WSL の強制停止では自動 rollback を保証しない。
中断後は installer を再実行し、同じ checkout の contract を使う `nix run .#dotfiles-doctor` で検査する。
再実行が失敗するか `agent/<client>` check が `fail` になった場合は、残った object を手で削除しない。
check ID から client を特定し、上記の client directory、`current`、visible binary を調査する。

client contract や timer を変えた後の system generation への反映は通常の [Rebuild](rebuild.md)に従う。
配備方式と信頼境界は [AI tooling](../architecture/ai-tooling.md#client-binary)と[セキュリティ境界](../architecture/security.md#agent-client-の供給経路)を参照する。

## Claude Code の規律読込

共通 policy は `/etc/claude-code/managed-settings.json` の `claudeMd` へ投影し、`~/.claude/CLAUDE.md` と `/etc/claude-code/CLAUDE.md` は配備しない。
公式資料の [Deploy organization-wide CLAUDE.md](https://code.claude.com/docs/en/memory#deploy-organization-wide-claude-md)では、`claudeMd` は managed または policy settings だけで有効になり、全 repository の session に user instructions より先に読み込まれる。
project の `AGENTS.md` 対応には Claude Code v2.1.277 以降が必要だが、その対応だけで全 project 共通の規律を代替しない。

Claude Code を採用して installer で更新し、generation を適用した後、別 file なしで共通 policy が読み込まれることを確認する。

```sh
claude --version
test ! -e ~/.claude/CLAUDE.md
test ! -e /etc/claude-code/CLAUDE.md
jq -e '.claudeMd | type == "string" and length > 0' /etc/claude-code/managed-settings.json
```

project instructions のない一時 directory で Claude Code を新規起動し、`/context` と「読み込まれている共通 policy の言語と作業規律を引用して」の応答を確認する。
共通 policy が示す日本語応答と作業規律を確認できなければ、ファイルの不在だけを根拠に移行済みと判断せず、managed settings の読込を調査する。
続いて project の `AGENTS.md` だけを持つ repository でも起動し、`/context` の Memory files に project の `AGENTS.md` が現れることを確認する。

## OMP の subscription login

OMP を対話起動し、`/login openai-codex` と `/login anthropic` を順に実行する。
browser または device flow は OMP の案内に従い、API key ではなく各サービスの subscription account を使う。

認証情報は OMP が `~/.omp/agent/agent.db` に保存する。
この file と、OMP が対話設定を書き込む `~/.omp/agent/config.yml` は dotfiles 管理外である。

advisor は期間限定の `opencode-go/longcat-2.5-preview-free:high` を主にし、`opencode-go/deepseek-v4.1-flash:high` を fallback にする。
モデルを変更するときは、新規環境用の `agents/clients/omp/assets/config.seed.yml` と既存環境の `~/.omp/agent/config.yml` をそれぞれ更新する。
seed は設定ファイルが存在しない場合だけ配備されるため、rebuild では既存環境のモデル設定を更新しない。
対して `AGENTS.md`、`skills/`、`agents/`、`mcp.json`、`lsp.json`、`hooks/` は Home Manager 管理なので、OMP 内から恒久変更せず正本を編集して rebuild する。
