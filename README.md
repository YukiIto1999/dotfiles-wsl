# dotfiles-wsl

WSL2 上の NixOS ホスト設定、AI コーディング CLI の共通ルール、MCP、SOPS 管理の secrets を `~/dotfiles-wsl` から再現する flake。

リポジトリルートを flake のルートとする。`/etc/nixos` は `~/dotfiles-wsl` への symlink にする。

このリポジトリは、Claude Code / Codex / OpenCode / Antigravity に同じルール、agents / skills、MCP gateway 設定を配備する。共通定義は `share/` に置き、各 CLI の形式へ変換する。

## 構成

| パス | 役割 |
|---|---|
| `flake.nix` | inputs(nixpkgs / nixos-wsl / home-manager / sops-nix / plugin sources)、nixosSystem の定義、`packages`(`dotfiles-install-clis` など)、`devShells`、`formatter`、`checks` |
| `modules/` | NixOS module 一式。`default.nix`(imports)、`options.nix`(`my.*` 型)、`wsl.nix` / `nix.nix` / `fonts.nix` / `secrets.nix`(git identity)、`accounts/`(GitHub account ごとの secrets と `gh` hosts 生成)、`mcp/`(gateway・docker network・`servers/<name>.nix`)、`clis/`(`my.clis` の CLI 一覧と CLI ごとの config、`share/` の配備)、`user/`(base user・git)、`commands.nix` + `commands/`(`dotfiles-*` 運用コマンドの生成元) |
| `pkgs/` | MCP server の build 定義(共通 `mk-mcp-server.nix` / `mk-npm-mcp.nix` helper 使用)、`agentgateway`、`agentmemory` の MCP server とバックエンド用 Docker image |
| `share/` | `AGENTS.md`(共通ルール)、`agents/`(subagent)、`skills/`(local skill) |
| `scripts/` | `bootstrap.sh`(初回セットアップ)、`pin-hash.sh`(pin 更新補助) |
| `secrets/` | `secrets.yaml`(SOPS + age)、`.sops.yaml` |
| `docs/adr/` | 構造に影響する決定の記録 |

## 前提

| 項目 | 置き場所 |
|---|---|
| リポジトリ | `~/dotfiles-wsl` |
| age 秘密鍵 | `/var/lib/sops-nix/key.txt`(root 専用、`0400`) |
| SOPS ファイル | `~/dotfiles-wsl/secrets/secrets.yaml` |

`/var/lib/sops-nix/key.txt` はホスト固有鍵とし、別ホストへ複製しない。通常の rebuild は既存鍵を読むだけで、鍵の生成や recipient の変更は行わない。

### age 鍵の enrollment

新規ホストは bootstrap の前に enrollment する。既存ホストを recovery identity から分離するときも同じ command を使うが、世代移行の有無は分けて扱う。復旧鍵は読み取り専用の外部媒体へ保管し、transaction が完了するまでだけホストへ接続する。

`dotfiles-sops-enroll` は、鍵生成、recipient 更新、暗号文更新、root key 交換を一つの transaction として扱う。手作業で `/var/lib/sops-nix/key.txt` を上書きしたり、tracked file に対して `sops updatekeys` を直接実行したりしない。
すべての operation は configured worktree の `~/dotfiles-wsl` から実行する。linked worktree や別 clone からの `prepare`、`apply`、`status`、`abort` は拒否する。

1. 作業ツリー全体を commit 済みにする。既存ホストの移行では、先にこの enrollment command と generation contract を通常 rebuild で配備し、`dotfiles-doctor` が current system と system profile の収束を確認できる状態にする。
2. ホストを一意に識別する ID を決める。`nixos` のように複数環境で重なる名前は避け、`desktop-nixos` などの安定した ID にする。
3. recovery identity で現在の暗号文を復号できることを確認し、host key と `secrets/` の候補を作る。

   ```bash
   cd ~/dotfiles-wsl
   nix run .#dotfiles-sops-enroll -- prepare \
     --recovery-key /media/offline/recovery-key.txt \
     --host-id desktop-nixos
   nix run .#dotfiles-sops-enroll -- status
   ```

   `prepare` は新しい identity を `/var/lib/sops-nix/key.next` に置き、候補を `.git/dotfiles-sops-enroll/` に置く。候補は既存 recipient を残したまま `sops updatekeys` し、recovery identity と `key.next` の両方で復号する。`secrets/.sops.yaml` と `secrets/secrets.yaml` はまだ変えない。作業ツリーに別の差分や untracked file があれば開始しない。

4. `PREPARED` の host ID と追加 recipient を確認し、適用する。

   ```bash
   nix run .#dotfiles-sops-enroll -- apply \
     --recovery-key /media/offline/recovery-key.txt \
     --yes
   ```

   新規ホストには旧 host key と旧 system generation がないため、この `apply` で鍵を昇格する。既存ホストでは repository だけを交換し、`key.txt` に旧鍵、`key.next` に新鍵を残して `PENDING` になる。鍵はまだ昇格しない。

5. 既存ホストで `PENDING` になった場合だけ、準備済み暗号文から system generation を作る。

   ```bash
   nix run .#dotfiles-rebuild
   ```

   enrollment marker がある間、通常の rebuild は拒否される。`generation-pending` だけは例外で、差分が `secrets/.sops.yaml` と `secrets/secrets.yaml` の二つに限定され、両方の hash が transaction と一致した場合だけ build と apply を許可する。この rebuild receipt は enrollment transaction ID に束縛される。WSL の停止後も `generation-pending` の同じ marker が残っていなければ再開しない。`apply` が generation を検証している間は marker が `generation-checking` になり、rebuild は再び拒否される。`dotfiles-rebuild` が WSL の停止と起動を指示した場合は、表示された transaction ID の手順を終えてから先へ進む。

6. 既存ホストでは同じ `apply` を再実行する。

   ```bash
   nix run .#dotfiles-sops-enroll -- apply \
     --recovery-key /media/offline/recovery-key.txt \
     --yes
   ```

   current system と system profile が新しい generation に一致し、その generation の暗号文を旧鍵と新鍵の両方で復号できた場合だけ続行する。次に、新鍵で復号できない system profile generation の番号と store path を表示し、その generation だけを削除する。残存 generation を新鍵で再検証してから `key.txt` と `key.next` を交換し、current generation が固定した sops-nix installer を新鍵で実行する。`--yes` は、この rollback history の削除も承認する指定である。削除対象は receipt の `closedGenerations` に残る。

7. 中断した場合は同じ `apply` を再実行する。journal の状態名だけではなく、旧・新ファイルの hash、current と next の recipient、current system、system profile、残存 generation を観測して再開位置を決める。`prepare` 完了後、`apply` が swap intent を記録する前までなら `nix run .#dotfiles-sops-enroll -- abort` で取り消せる。swap intent 以後は repository 交換前でも rollback せず、`apply` で前進復旧する。交換直前または交換後に tracked file や退避側が変わった場合は削除せず、表示された `.git/dotfiles-sops-enroll/<transaction-id>/secrets` を保全して停止する。
8. `git diff -- secrets` で二つの tracked file だけが変わったことを確認し、同じ commit に記録する。復旧鍵をホストから取り外してから bootstrap または通常運用へ戻る。

enrollment command、`dotfiles-rebuild`、bootstrap は Git common dir の同じ operation lock を使う。同時実行は失敗する。command 間では SOPS marker と rebuild receipt が transaction を保護する。active rebuild があれば enrollment の変更操作と bootstrap を拒否し、enrollment の `status` だけを許可する。active enrollment があれば bootstrap を拒否し、rebuild は前述の `generation-pending` 経路だけを許可する。`generation-checking` は generation barrier の検証中またはその直後に停止した状態なので、rebuild ではなく enrollment の `apply` を再実行する。`dotfiles-rebuild --status` が `idle`、enrollment の `status` も `idle` になり、`apply` が recovery と current host の復号成功を表示してから次へ進む。

既存ホストで閉じた enrollment 前の system generation は、通常の `nixos-rebuild --rollback` では使えない。旧 Git commit へ戻す場合も、外部の recovery identity を使って現在の recipient model へ更新し、新しい generation として build する。旧 store closure の `activate` を直接実行しない。

現在の repository metadata は recovery recipient だけを持ち、`modules/secrets.nix` の `my.sops.enrollmentState` も `migration` である。実環境で上の transaction を完了し、home 側の旧鍵を削除してから `enrolled` へ変更する。コードの配備だけを migration 完了とは扱わない。

### 別ホストで再現する手順

再現対象は tracked source と `flake.lock` から生成する system / Home Manager 設定である。age の host key、AI CLI が保持する login session、agentmemory のデータはホスト固有なので複製しない。AI CLI 本体も bootstrap 時点の latest を取得する外部状態であり、`flake.lock` から同じ版を再現しない。

1. NixOS-WSL を用意し、このリポジトリを `~/dotfiles-wsl` へ clone する。
2. recovery key を一時的に接続し、前節の `prepare` と `apply` を新規ホスト上で実行する。host key は command が root 領域へ生成するため、既存ホストから秘密鍵をコピーしない。
3. `git diff --check` と `git diff -- secrets` で、変更が `secrets/.sops.yaml` と `secrets/secrets.yaml` だけであることを確認する。初回 bootstrap 前は Git identity がまだ配備されていないため、この時点では commit しない。必要なら暗号化済み差分を外部媒体へ退避する。
4. recovery key をホストから外し、`sudo bash scripts/bootstrap.sh` を実行する。bootstrap は tracked file の変更を含む Git flake を build するため、enrollment の差分を消さない。
5. 初回の boot generation を読むため WSL を一度停止・起動し、`dotfiles-doctor` を実行する。
6. sops-nix が配備した Git identity を使い、二つの secrets file を同じ commit に記録する。その commit を利用する全ホストへ同期してから、別の新規ホストを enrollment する。

暗号化済み差分を退避する場合は、平文ではなく Git patch を保存する。

```bash
git diff --binary -- secrets > /media/offline/desktop-nixos-enrollment.patch
```

2台目以降も同じ手順を使う。既存ホストの `/var/lib/sops-nix/key.txt` や `~/.config/sops/age/keys.txt` をコピーして済ませない。

## 初回セットアップ

```bash
cd ~/dotfiles-wsl
sudo bash scripts/bootstrap.sh
```

bootstrap は次を実行する。

| 順序 | 内容 |
|---|---|
| acquire_operation_lock | enrollment、rebuild、bootstrap の同時実行を拒否 |
| reject_active_enrollment | command 間に残る enrollment marker があれば bootstrap を拒否 |
| reject_active_rebuild | command 間に残る rebuild receipt があれば bootstrap を拒否 |
| register_safe_directories | root がリポジトリを扱えるよう `safe.directory` を登録(冪等) |
| preflight | flake / lock / secrets の存在と、enrollment 済み age key の owner / mode を確認 |
| verify_tracked_flake_files | untracked file が flake build から見えないため、無いことを確認 |
| verify_secrets | `nix shell .#sops -c sops -d secrets/secrets.yaml` で復号確認 |
| install_ai_clis | `nix run .#dotfiles-install-clis` で CLI 本体を upstream から `~/.local/bin` へ配置 |
| install_boot_generation | flake が固定した `config.system.build.nixos-rebuild` を store path へ build し、`boot --no-reexec` を実行 |
| link_nixos | `/etc/nixos` を `~/dotfiles-wsl` に向ける |

完了後、PowerShell から WSL を再起動して検証する。

```powershell
wsl -t NixOS
wsl -d NixOS
```

```bash
dotfiles-doctor
```

## 保守環境

clone 後に `direnv` を許可すると、リポジトリへ入ったときに flake の devShell が有効になる。

```bash
direnv allow
```

`.envrc` は nix-direnv の fallback を無効にする。flake の評価に失敗した場合は過去の開発環境へ戻さず、その場で失敗させる。

direnv を使わない場合は、同じ環境へ明示的に入る。

```bash
nix develop
```

devShell は `flake.lock` で固定した `actionlint`、`deadnix`、`jq`、`nixfmt-tree`、`shellcheck`、`statix`、`taplo`、`yq` を提供する。リポジトリの Nix ファイルを整形するコマンドは次のとおり。

```bash
nix fmt
```

flake の devShell はこのリポジトリ固有の保守 toolchain、checks は CI の検査を所有する。Home Manager は日常操作と editor 連携の tool を所有する。`jq`、`yq`、`shellcheck` は用途が異なるため Home と devShell の両方に含める。formatter は devShell と checks で `nixfmt-tree` に統一し、Home Manager の `nixfmt` は editor から単一ファイルを整形するために残す。

`devenv` は各プロジェクトの `devenv.nix` から開発環境を構築するため、Home Manager がユーザー環境へ配備する。`direnv` と nix-direnv の Bash 連携も Home Manager に集約する。devenv の project environment を取得する `devenv.cachix.org` は NixOS の substituter に維持する。

仕様は [Nix の `nix develop`](https://nix.dev/manual/nix/2.33/command-ref/new-cli/nix3-develop)、[devenv の導入手順](https://devenv.sh/getting-started/)、[nixfmt の project formatter](https://github.com/NixOS/nixfmt#in-a-project)を参照する。

## 再ビルド

通常更新は `dotfiles-rebuild` を使う。先に適用内容だけを確認する場合は `--plan` を付ける。

```bash
dotfiles-rebuild --plan
dotfiles-rebuild
```

current generation の command を更新する前でも、checkout から同じ処理を実行できる。

```bash
nix run .#dotfiles-rebuild -- --plan
nix run .#dotfiles-rebuild
```

rebuild は untracked file を拒否した後、flake の `sourceSnapshot` を `nix build --out-link` で一度だけ生成する。
source と candidate は、それぞれの build command が作る temporary GC root で生成中から保護する。
同じ immutable snapshot に対して flake check と candidate build を実行し、`nvd` で current system との差分を表示する。
`--plan` はここで終了するため system profile と runtime は変えない。ただし、snapshot と candidate の build により
Nix store と cache は更新される。candidate と実行中 generation の WSL default user も検査する。
`my.username` や `wsl.defaultUser` の変更は home、repository path、所有権を伴う host identity migration
なので、通常 rebuild と `--plan` は終了 status 2 で拒否する。

snapshot 取得から activation と doctor の終了までは Git common dir の operation lock を保持する。linked worktree を含め、SOPS enrollment が同時に repository と host key を遷移させることはない。

apply では build 済み candidate の store path だけを、flake が固定した上流 `nixos-rebuild` の store path へ
`--store-path --no-reexec --sudo` 付きで渡す。
checkout の評価と build は一般ユーザー、system profile の更新と activation だけは root で実行する。
effect の計算前に current、booted、system profile の store path を固定する。`nvd` と classifier はその
current/booted closure だけを参照する。persistent GC root の作成後と activation の直前にも同じ三つを照合する。

apply の前に `$GIT_COMMON_DIR/dotfiles-rebuild/active.json` を作り、source、candidate、実行中 generation、booted
generation、既存 system profile、effect、activation と verification の結果を記録する。candidate と
回復対象は indirect GC root で保護する。再開時も `nix-store --add-root ROOT --realise STORE_PATH` を冪等に実行し、user-facing
root と `/nix/var/nix/gcroots/auto` の登録を照合する。receipt storage の三つの directory は owner、mode、
symlink でないことを全操作の前に検査する。receipt と GC root の file、link、rename は Nix の auto-root
directory を含む親 directory まで同期してから activation または WSL 停止手順へ進む。receipt schema v2 は
activation attempt ごとの runtime baseline を保持する。再開時も baseline から外部 generation へ勝手に追随しない。
activation の結果と次の state は一回の atomic receipt 更新で確定し、矛盾する中間 state を永続化しない。
baseline の照合に失敗した transaction は activation と自動 rollback を行わず、観測した三つの path を
`aborted` receipt に記録して archive する。

生成された環境の `nixos-rebuild` は直接実行を status 2 で拒否する。通常の system generation 更新を
`dotfiles-rebuild` に限定し、bootstrap も同じ operation lock の内側から flake 固定の上流実体を呼ぶ。
これらの対応経路では、baseline の照合から activation まで別の対応経路が割り込まない。

root が `nix-env --profile /nix/var/nix/profiles/system`、古い generation の store path、
`switch-to-configuration`、`nix run nixpkgs#nixos-rebuild` を直接実行する操作は transaction の保証外である。
receipt と operation lock を迂回し、再開時に runtime drift として中止されるか、照合直後へ割り込む可能性がある。
緊急復旧でもこれらを通常手順にはせず、まず receipt の `--resume` または `--rollback` を使う。

再開時に transaction が所有できる変化も action ごとに限定する。`switch` は current と profile について
baseline または target を許可し、booted は baseline のまま要求する。`boot` は profile だけに baseline または
target を許可し、current と booted は baseline のまま要求する。三つすべてが target へ収束済みの場合だけ、
再起動済みの boot として受け入れる。これ以外の mixed state は外部変更として `aborted` にする。

回復対象は rebuild 開始時の `/run/current-system` である。既存 system profile が current と違っていても
開始を拒否せず、profile は `previous.displacedProfile` として記録するだけで自動 rollback には使わない。
profile に登録済みでも、実際に起動または live activation された証拠にはならないためである。

変更内容に応じた処理は次のとおり。

| effect | apply | WSL 操作 |
|---|---|---|
| `switch` | live switch 後に candidate の doctor を実行 | 不要 |
| `switch-restart` | live switch | 停止と起動を 1 回、その後 doctor |
| `boot-restart` | boot generation へ登録 | 停止と起動を 1 回、その後 doctor |
| `boot-two-stage` | boot generation へ登録 | root 起動を挟んで 2 回停止、その後 doctor |

`wsl.conf` と activation interface が同時に変わる場合、または比較に必要な boot metadata がない場合は
二段階になる。`wsl.defaultUser` の差も classifier では二段階に分類するが、通常 rebuild は前述の identity
migration として apply 前に拒否する。

停止が必要な transaction は終了 status 3 で active のまま残る。PowerShell で実行する command は、
distribution 名、candidate 内の helper、transaction ID を単一引用符で固定して表示する。再起動の完了は
`/proc/sys/kernel/random/boot_id` と systemd の `UserspaceTimestampMonotonic` の組で確認する。
`boot-two-stage` は first boot と final boot が異なる systemd manager instance になるまで完了しない。

中断後の操作は次のとおり。

```bash
dotfiles-rebuild --status
dotfiles-rebuild --resume <transaction-id>
dotfiles-rebuild --rollback <transaction-id>
```

`--resume` は receipt に固定した candidate を再適用または再検証する。`--rollback` は開始時の running
generation を現在の状態に対して再分類し、同じ一段階または二段階の state machine で戻す。active receipt
がある間は新しい build を開始しない。終了 status 4 は activation 失敗、5 は target doctor 失敗、
2 は不正な引数、receipt、runtime state を表す。activation と doctor の失敗を同じ成功・失敗へ丸めない。
schema v3 の target doctor は report v1 を JSON で返す。rebuild は report が単一の JSON document であること、manifest schema、
check、summary、doctor の終了 status と outcome の対応を検証する。doctor が `fail` または `error` にした安定 ID は
receipt の `verification.failedCheckIds` に保存する。旧 receipt ではこの field の欠落を受理するが、明示的な `null` や
重複 ID は不正とする。schema v3 の generation から schema v2 の recovery target へ戻す場合に限り、rebuild は
旧 doctor を引数なしで1回実行し、status 0 / 1 を `legacy.doctor` check を持つ report v1 へ変換する。この移行経路を
forward verification や schema が不明な target には適用しない。
完了または drift で中止した receipt は
`$GIT_COMMON_DIR/dotfiles-rebuild/receipts/<transaction-id>.json` へ移し、transaction 用 GC root を削除する。

flake input の更新は build と分け、明示的に `nix flake update` を実行してから rebuild する。

## 検証

`nix flake check` と `dotfiles-doctor` は検査対象が異なるため、どちらも必要になる。flake check は評価した source から system closure と設定を生成できることを apply 前に検査する。doctor は apply 後の current generation が宣言した期待値と、system profile、systemd、SOPS host key、home 配下の CLI、MCP gateway の実状態が一致することを検査する。

通常は人向け出力を使う。rebuild や診断ツールからは同じ result core を JSON で取得する。

```bash
dotfiles-doctor
dotfiles-doctor --format json
```

| status | outcome | 意味 |
|---:|---|---|
| `0` | `healthy` | `pass` と `warn` だけで、実用状態に収束している |
| `1` | `degraded` | runtime の不一致または依存 probe の `blocked` がある |
| `2` | `invalid` | 有効な形式で起動したが、manifest または result core の contract が壊れている |
| `2` | なし | 引数が不正で、result core を生成する前に終了した |
| `130` / `143` | なし | INT / TERM を受け、session cleanup を試行して終了した |

JSON report v1 は `schemaVersion`、`manifestSchemaVersion`、`outcome`、status 別件数を持つ `summary`、
`checks` を返す。各 check は安定 `id`、`foundation` / `local` / `system` / `active` の phase、
`pass` / `warn` / `fail` / `error` / `blocked`、subject、expected、observed、message、`durationMs` を持つ。
human 出力もこの result core だけから生成する。

doctor の期待値は current generation の `/run/current-system/etc/dotfiles/doctor.json` に manifest v3 として収録する。
開始時に manifest を immutable な store path へ固定し、configured user と `HOME`、current generation、system profile、
実行中 doctor、WSL cold-start state を foundation で検査する。foundation が失敗した場合は local、system、active phase を
実行せず `blocked` とする。全 probe の後にも current、profile、manifest が同じ generation を指すことを再確認する。
mutable な checkout や `share/AGENTS.md` の表は inventory として読まない。次をすべて満たした場合だけ status 0 になる。

- system profile と実行中の doctor が current generation を指す
- WSL cold-start state が `switch` で、追加の停止・起動を必要としない
- 必須 unit の `LoadState`、`ActiveState` と、宣言した場合の `SubState`、`Result` が一致する。各 unit は1回の `systemctl show` で検査する
- `/var/lib/sops-nix` が root `0700`、host key が root `0400` になっている。host/recovery key の移行中は home 側の旧 age key を警告し、移行完了後に policy を `reject` へ切り替えて残存を失敗にする
- health registry に登録した Claude、Codex、agentgateway、OpenCode の agentmemory capture plugin と、trusted project 用の `.codex/config.toml` が current generation の source と byte 単位で一致する
- 各 AI CLI が `~/.local/bin` の宣言パスから実行され、rules file が source と一致し、期待する各 `SKILL.md` と各 agent file が存在する
- OpenCode と Antigravity の gateway file が current generation の immutable source と byte 単位で一致する
- `wslview` が current generation の宣言した実体を指し、`cmd.exe /d /c exit 0` の probe が5秒以内に成功する
- MCP が `initialize`、`notifications/initialized`、全ページの `tools/list`、session `DELETE` を完走し、全 target が tool を公開する

systemd と root probe、CLI `--version`、Windows probe、MCP request の上限は各5秒である。MCP lifecycle 全体は30秒以内とし、
そのうち5秒を session `DELETE` 用に予約する。pagination は20ページ、response は1 requestあたり1 MiBまでとする。
MCP client は最新 stable の `2025-11-25` を要求する。agentgateway 1.3.1 は multiplex した upstream の最小 version を
Streamable HTTP front の negotiated version として返し、この構成では `2024-11-05` が実測される。そのため
`2024-11-05`、`2025-03-26`、`2025-06-18`、`2025-11-25` を bridge の許容値にする。これは汎用 client として
旧 HTTP+SSE transport fallback を実装したという意味ではない。

doctor は secret の値、AI CLI の配布元・内容・期待版・login session、skill 本文と agent file の内容、checkout の clean 状態を検査しない。CLI は `--version` が上限内に非空で成功することだけを確認し、版を期待値と比較しない。source と build の検査は `dotfiles-rebuild` と flake check が行う。enrollment では host identity と recovery identity、bootstrap では host identity による秘密値の復号を確認する。MCP lifecycle は [MCP 2025-11-25 lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle) と [Streamable HTTP transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports) に従う。agentgateway の version 集約は [v1.3.1 `merge_initialize`](https://github.com/agentgateway/agentgateway/blob/v1.3.1/crates/agentgateway/src/mcp/handler.rs#L360-L396) に基づく。

## AI コーディング CLI

CLI 本体は Nix でインストールしない。更新頻度が高く常に最新が望ましいため、各 CLI の公式配布を `~/.local/bin` に置く。dotfiles は設定・agents・skills を管理する。

| command | 配置 | 更新元 |
|---|---|---|
| `claude` | `~/.local/bin/claude` | Anthropic 公式 installer |
| `codex` | `~/.local/bin/codex` | OpenAI GitHub Release |
| `opencode` | `~/.local/bin/opencode` | Anomaly GitHub Release |
| `agy` | `~/.local/bin/agy` | Google 公式 installer |

`modules/clis/` は `share/AGENTS.md`、`share/agents/*.md`、plugin / local skills を各 CLI の形式で配備する。Claude は agent の Markdown をそのまま使う。Codex は TOML、OpenCode は tools 用の形式へ変換する。Antigravity は静的な agent 機能を持たないため、rules / skills / gateway 設定だけを配備する。

MCP gateway の登録方法は CLI ごとに異なる。Claude は CLI が実行時に管理する `~/.claude.json` に `claude mcp add` で登録する。Codex は `/etc/codex/config.toml` に管理設定を置き、ユーザーが初期化する home 配下の config と分ける。OpenCode / Antigravity は home の MCP 設定ファイルへ置く。

Codex の `workspace-write` sandbox は作業ディレクトリに加え、この checkout の `.git` だけを書き込み可能にする。許可パスは Home Manager が `my.dotfilesDir/.codex/config.toml` へ生成し、Codex がこのリポジトリを trusted project として読む場合だけ有効になる。`/etc/codex/config.toml` には全 project 共通の gateway と hooks だけを置く。

## MCP

全 CLI は MCP gateway だけに接続する。gateway は systemd service として動作し、stdio server を子プロセスとして起動する。SearXNG など常駐が必要なプロセスだけ Docker で動かす。

```text
Claude Code / Codex / OpenCode / Antigravity
        |  http://localhost:8765/mcp  (loopback)
        v
   agentgateway (systemd)
        |  stdio (MCP server を起動)
        v
 context7 / probe / searxng / crawl4ai /
 memory / playwright / github-<account>
        |  loopback (常駐プロセスを使う target のみ)
        v
 docker network mcp-backends:
 searxng + valkey / crawl4ai / agentmemory engine
```

- gateway は `127.0.0.1:8765` のみで待ち受ける。`my.gatewayPort` で宣言する。
- MCP server はすべて stdio で gateway から起動する。HTTP target、OCI image、mcp-proxy は使わない。
- GitHub MCP は account ごとの wrapper が `/run/secrets` から PAT を読んで起動する。Docker コンテナではないため、`mcp-backends` network と `docker inspect` には露出しない。
- 常駐プロセス(searxng / valkey / crawl4ai / agentmemory engine)だけ `mcp-backends` network の Docker で動かす。stdio server は `127.0.0.1` に公開した port 経由で接続する。
- Playwright MCP は host の Chromium を headless で起動する。専用 daemon と Docker image は使わない。

## agentmemory

長期記憶。MCP target `memory` の tools に加え、engine 同梱の lifecycle hooks が全 CLI のセッションを自動観測する。

```
Claude Code (managed-settings.json) --\
Codex (/etc/codex/config.toml)      ---+-- agentmemory-hook-<event> --> REST 127.0.0.1:3111/agentmemory/observe
OpenCode (plugins/ 自動ロード)      --/
```

- hook 実体は `pkgs/agentmemory` が engine 同梱 script を `agentmemory-hook-<event>` として `/run/current-system/sw/bin` に公開する。宣言は `modules/mcp/servers/memory.nix` に集約。
- `session-start` は `AGENTMEMORY_INJECT_CONTEXT=true` で過去記憶をセッション冒頭に注入する。`stop` / `session-end` がセッション要約と登録を行う。
- OpenCode は `~/.config/opencode/plugins/agentmemory-capture.ts` の自動ロードで同等の観測を行う。
- LLM provider は OpenCode Go の OpenAI 互換 endpoint を使う。model は `minimax-m2.7`、embedding provider は `none`。
- 状態確認: `xh GET http://127.0.0.1:3111/agentmemory/health`、`memory_diagnose` / `memory_audit` tools。

## Secrets と identity

| key | 用途 |
|---|---|
| `identity/default/name` | default git user.name |
| `identity/default/email` | default git user.email |
| `identity/work/name` | work identity の git user.name |
| `identity/work/email` | work identity の git user.email |
| `accounts/<account>/username` | `gh` と GitHub MCP の username |
| `accounts/<account>/token` | `gh` と GitHub MCP の PAT |
| `opencode/go_api_key` | agentmemory が OpenCode Go を呼び出す API key |
| `searxng/secret_key` | SearXNG の `server.secret_key` |

`identity/work/*` は `my.workIdentity != null` のときだけ必要。

## 変更箇所

| やりたいこと | 触る場所 |
|---|---|
| GitHub account を増減 | `flake.nix` の `my.accounts`、`secrets/secrets.yaml` の `accounts/<account>/*` |
| work identity を変える | `flake.nix` の `my.workIdentity`、必要なら `secrets/secrets.yaml` の `identity/work/*` |
| default git identity を変える | `secrets/secrets.yaml` の `identity/default/*` |
| local skill を足す | `share/skills/<name>/SKILL.md` を置いて `git add` + `dotfiles-rebuild` |
| subagent を足す | `share/agents/<name>.md` を置いて `git add` + `dotfiles-rebuild` |
| 共通ルールを変える | `share/AGENTS.md` |
| CLI 固有の設定を変える | `modules/clis/<name>/` 配下のテンプレート |
| CLI を増減 | `modules/clis/<name>/` を足し、`modules/clis/default.nix` の imports に登録 |
| MCP server を増減 | `pkgs/<name>` を build 定義として足し、`modules/mcp/servers/<name>.nix` に target を追加、`modules/mcp/default.nix` の imports に登録 |
| binary cache を増減 | `modules/nix-caches.nix` |
| secret を足す | 消費する module に `sops.secrets` を宣言し、`secrets/secrets.yaml` に値を足す |

変更後は rebuild する。

```bash
dotfiles-rebuild
```

`dotfiles-rebuild` が `switch` と判定した変更は WSL を止めず、live switch 後に doctor まで実行する。停止・起動が必要な場合だけ、終了時に表示される PowerShell command を実行する。

## セキュリティ

- gateway は loopback 限定で認証は持たない。同一ユーザーのプロセスは gateway 経由で GitHub の書き込み操作などを実行できる。被害を絞るため、PAT は fine-grained + 最小スコープにする。
- runtime migration 完了後は、ホスト固有の `/var/lib/sops-nix/key.txt`(directory は root `0700`、key は root `0400`)だけを置く。`~/.config/sops/age/keys.txt` に複製しない。通常の secret 編集は `sudo SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt sops secrets/secrets.yaml` を使う。
- 現在の `my.sops.enrollmentState = "migration"` から doctor manifest の `sops.homeKey.policy = "warn"` を導出する。host key とオフライン復旧鍵の双方で復号し、旧 home key を削除した後に state を `enrolled` へ変更すると、policy は `reject` になる。
- オフライン復旧鍵は host key と同じ age key group に登録するが、通常運用するホストへ常置しない。recipient の追加と削除には `sops updatekeys` を使い、変更後は各 identity で個別に復号を確認する。
- enrollment の root helper は任意 path を開かない。候補 ciphertext は stdin で transient service に渡し、host identity は systemd credential として `DynamicUser` の verifier にだけ公開する。verifier は private network、read-only system、空の環境で実行する。

## CI

`.github/workflows/check.yml` が push / PR で `nix flake check` を実行する。checks は `nixos-toplevel`(system closure の build)、`doctor-runtime`(runtime failure matrix と MCP lifecycle)、`doctor-manifest-contract`(実配備 manifest と Home Manager / Codex / SOPS / WSL 宣言の一致)、`config-artifact-contract`(実配備 source と構文検査 projection の同一性、実値の反映)、`sops-policy`(鍵の自動生成禁止、owner / mode、recipient metadata、enrollment の通常系・拒否系・中断再開)、`sops-verifier-runtime`(NixOS VM 上の sops-nix activation、transient verifier、generation barrier、鍵昇格、installer 再実行)、`development-tool-ownership`(direnv / devenv の所有レイヤーと Cachix)、`actionlint`(GitHub Actions workflow の静的検査)、`deadnix`、`shellcheck`、`statix`、`nixfmt`(`treefmt --ci`)、`config-syntax`(各 module が実配備へ渡す JSON / TOML / YAML artifact の構文検査)。

## License

[MIT](LICENSE)
