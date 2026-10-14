# Agent client の選択と更新

**読み手:** client の試用、交換、更新、rollbackを行う運用者。
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
登録だけの client は rules、Skill、subagent、config、公開 command、供給の更新対象、health observation、共通 policy の能力表に含まれない。

宣言を保存してから、[Rebuild](rebuild.md)の手順で plan の対象を確認し、差分を commit して適用する。
適用の Home Manager activation が、採用した client の存在しない profile だけを lock の baseline から作る。
新しい generation の manifest と doctor に目的の client だけが現れることを確認してから、その client の認証と対話起動を行う。

```sh
dotfiles-rebuild --plan
# Rebuild の手順に従って commit と適用を行う
dotfiles-agent-supply manifest | jq 'map(.name)'
dotfiles-agent-supply status
dotfiles-doctor
```

## 供給

各 client の binary は、供給元 [llm-agents.nix](https://github.com/numtide/llm-agents.nix) が package 化した版を、client 別の native Nix profile で受け取る。
adapter の `supply.package` が供給元の package attribute を選び、`bin/<binary>` を実行 file とする。
Claude Code、Codex、OMP、OpenCode、Antigravity は同じ供給元に package があり、供給元自身の固定 nixpkgs と Bun で build される。
host の stable nixpkgs へは follows させない。

利用者は「製品の最新 release」ではなく「供給元が package 化した最新版」を日次で取得することを承認している。
供給元の package 化に遅れがある間は、その遅れた版が最新である。
供給元 HEAD の取得成功を製品の最新版と同一視しない。

| 役割 | 正本 |
|---|---|
| 供給元の採用と初回 baseline | `flake.nix` の `llm-agents` input と `flake.lock`。baseline は採用 client の package だけを system closure へ含める |
| 稼働中の版 | `~/.local/share/dotfiles/agent-profiles/<client>/profile` の世代。root の lock、Git HEAD、system generation は日次更新で書き換えない |
| 更新、rollback、retention | `dotfiles-agent-supply` だけ。baseline 初期化、手動更新、timer、rollback が同じ owner を通る |
| 公開 command | `~/.local/share/dotfiles-agent/bin/<binary>` の wrapper。profile の `bin` は PATH へ出さない |

### 操作

```sh
dotfiles-agent-supply status              # 世代、store path、版、供給 revision
dotfiles-agent-supply update              # 採用済みの全 client を最新へ
dotfiles-agent-supply update omp codex    # 指定した client だけ
dotfiles-agent-supply rollback omp        # omp だけを直前の世代へ戻す
```

`automaticUpdates.clients` の既定は空であり、空なら自動更新 service、timer、health observation を配備しない。
共通 workstation profile は OMP だけを日次更新の対象にしている。
timer の service は `dotfiles-agent-supply update --automatic` を実行し、起動予定と直近の結果を systemd から確認する。

```sh
systemctl status dotfiles-agent-autoupdate.timer
systemctl status dotfiles-agent-autoupdate.service
```

Claude Code の background updater は供給元 package が `DISABLE_AUTOUPDATER=1` を設定し、managed settings も同じ値を置く。
OpenCode の起動時 updater は配備する config の `autoupdate=false` で無効にする。
供給の更新経路を `dotfiles-agent-supply` に一本化し、client 自身の更新経路を重ねない。
Antigravity は `agy update` ではなく、同じ供給で更新する。

### 更新の規則

1. 供給元の最新 revision を解決し、その exact revision から client の package を build する。
2. build した候補に root を置き、空の環境で版を観測する。
3. 観測に成功した候補だけを profile の新しい世代として公開する。
4. current と直前の世代だけを残し、それ以前の世代 link を除く。

取得、build、probe のどれかが失敗した client は旧版のまま残り、他の client の更新は続く。
失敗した client 名は終了時に一度だけ報告され、service は非ゼロで終わる。
外部からの取消は、実行中の子の終了を待ってから終了し、次の client を始めない。
取消を記録した後は、新しい取得、build、probe、profile の切替、世代削除を始めない。
開始済みの profile 切替は完了まで待ち、成功した切替の記録を残してから取消として終了する。
同じ revision の再実行は再 build せず、current と同じ store path になる revision は公開しない。
実行中の session は終了せず、新しい版は次回起動から使う。

rollback は取得も build も行わず、直前の世代を probe してから切り替える。
戻した版の store path は記録し、次の更新が同じ版を再公開しない。
rollback の後は戻し済みの新しい世代を除くため、保持する世代が一つになり、続けての rollback は拒否される。
rollback は対象 client の profile だけを戻し、他の client や system generation は戻さない。
拒否記録は直近8件を保持し、同じ path を再び戻した場合は最新の拒否として扱う。

system generation と client profile は別の正本であり、`dotfiles-rebuild --rollback` だけでは client の版は戻らない。
system を戻した後は `dotfiles-agent-supply status` で、稼働する版が adapter の設定と合うことを確認する。

### GC と稼働中の session

世代 link は Nix の GC root であり、候補の build 後は公開まで候補 root が実体を保持する。
起動した session は、profile を解決した binary と、起動時に確定した managed config、hook、gate、runtime、Skill、rules、subagent の不変 source を、全子の終了まで自分の root で保持する。
初回 seed はこの保護対象に含めない。
そのため retention や `nix-collect-garbage` が、稼働中の session が使う旧版や旧 hook を消さない。
保持する root の取得に失敗した起動は、保護なしでは続けず拒否される。

### Profile の安全

`~/.local/share/dotfiles/agent-profiles/<client>` は利用者所有の real directory で、親も含めて symlink と group・other の書込を許さない。
更新の前後で親 directory の identity を照合し、差し替わっていれば公開せずに失敗する。
`profile`、世代 link、候補、receipt が自分の object でない場合は、変更も削除もせずに失敗する。
native profile の切替は atomic だが、この確認を代替しない。
同一 UID の悪意ある process が、検査と更新の間に親を差し替える攻撃は防がない。
`SIGKILL` や電源断で中断した公開は、次の更新が未公開の世代を除いて整合を戻す。

## 採用解除

採用から外すと Home Manager と NixOS が管理する設定、公開 command、更新対象、通常の health は次の適用で外れる。
client 別 profile、認証、会話履歴、初回 seed 後の対話設定、稼働中の session は削除しない。
非公開に残る profile の世代は GC root として残り、容量を使う。
既存 session は停止せず、これらの利用者 data を残したまま再採用でき、再採用では既存 profile を巻き戻さない。
不要になった profile と利用者 data の削除は、稼働中 session と各 client の手順を確認して別途行う。

## 供給方式の切替

旧方式の release tree と upstream installer の binary は、`~/.local/share/dotfiles/agents/<client>`、`~/.local/bin/<binary>`、`~/.local/share/claude/versions` に残り、新方式は別の `agent-profiles` を使う。
二つの方式は共有する書込 object を持たず、新方式は旧方式の object を変更も削除もしない。

所有の移管は generation 単位で行う。

1. 新しい generation を適用すると、公開 command は新しい profile を指す wrapper になり、profile は baseline から作られる。baseline は lock が固定した版であり、旧方式で稼働していた版より古いことがある。次の更新で最新へ進む。
2. 稼働中の session は旧 binary のまま動き続け、新しい session から新しい profile を使う。
3. 同じ client の旧 release writer が client root の flock を握っている間、新方式は同じ client を更新せずに失敗する。旧 root がない client では待たない。
4. system generation を旧方式へ戻すと、旧 generation の writer と wrapper が旧 object を使い、新方式の timer と command は消える。実行中の更新 service は generation の切替で停止し、drain してから終わる。手動で起動した更新は、旧 root の lock で旧 writer と並走しない。
5. 旧 writer が使った object と新 profile は互いに触れないため、どちらの方向へ戻しても版の巻き戻しは起きず、再度新方式へ進めば既存 profile を巻き戻さずに続ける。

旧方式の object は、稼働中の session がないこと、旧 generation へ戻す予定がないことを確認してから、利用者が手動で削除する。
source から旧 installer、旧 CLI、release tree 用の observation と fixture は除かれている。

## Claude Code の規律読込

共通 policy は `/etc/claude-code/managed-settings.json` の `claudeMd` へ投影し、`~/.claude/CLAUDE.md` と `/etc/claude-code/CLAUDE.md` は配備しない。
公式資料の [Deploy organization-wide CLAUDE.md](https://code.claude.com/docs/en/memory#deploy-organization-wide-claude-md)では、`claudeMd` は managed または policy settings だけで有効になり、全 repository の session に user instructions より先に読み込まれる。
project の `AGENTS.md` 対応には Claude Code v2.1.277 以降が必要だが、その対応だけで全 project 共通の規律を代替しない。

Claude Code を採用して供給で更新し、generation を適用した後、別 file なしで共通 policy が読み込まれることを確認する。

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

`dev` は `anthropic/claude-sonnet-5-5:xhigh` を主モデル、`retry.fallbackChains.dev` の `openai-codex/gpt-6.1-sol:xhigh` を fallback にし、`task.agentModelOverrides.implementer` の `@dev` 参照で実装エージェントへ接続する。
この参照により、親セッションのモデル選択を変えずに、`modelRoles.dev` で実装モデルを選べる。

OpenRouter は `disabledProviders` で無効にし、Judge は `modelRoles.judge: typesafe/jev-latest` と `retry.fallbackChains.judge: []` で TypeSafe 公式 API へ固定する。
Judge 未設定時の OMP 内蔵候補には OpenRouter が含まれるため、chat のモデル選択だけではその呼出しを防げない。
TypeSafe の API key は SOPS store の `typesafe/api_key` に保持し、`models.yml` の command-resolved secret から要求時に復号する。
取得 command と公式 endpoint の seed は `agents/clients/omp/module.nix` が生成し、key の値を `models.yml` や OMP の認証 DB へ複製しない。
command は非対話の `sudo` で host key を使うため、実行権限がなければ認証を利用できない。
native Judge を使う `find.enabled` は既定の `auto` に任せる。
project の `disabledProviders` 配列は global の配列を置き換えるため、project 側に指定する場合も `openrouter` を含める。

advisor は期間限定の `opencode-go/longcat-2.5-preview-free:high` を主にし、`opencode-go/deepseek-v4.1-flash:high` を fallback にする。
モデルを変更するときは、新規環境用の `agents/clients/omp/assets/config.seed.yml` と既存環境の `~/.omp/agent/config.yml` をそれぞれ更新する。
`config.yml` と `models.yml` の seed は配備先が存在しない場合だけ作成するため、rebuild では既存環境の可変設定を更新しない。
対して `AGENTS.md`、`skills/`、`agents/`、`mcp.json`、`lsp.json`、`hooks/` は Home Manager 管理なので、OMP 内から恒久変更せず正本を編集して rebuild する。
