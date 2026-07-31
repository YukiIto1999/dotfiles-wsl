# Handoff

**対象期間:** 2026-07-31 の対話全体
**状態:** 構造移行の第 5 段の途中。実機未反映。未 commit の変更あり。

この文書は追跡対象外である。作業を引き継いだら読み、完了したら消す。

---

## 1. 出発点と現在地

開始時の依頼は `docs/superpowers/plans/2026-07-31-mcp-remediation-roadmap.md` の実行だった。MCP の timeout を session lifecycle、endpoint 分離、常駐 HTTP front の順で解消する計画である。

roadmap Task 1 の構造監査と、session 安定化計画の Task 1-5 を完了した後、依頼者の指摘により作業の性質が変わった。文書と構造の欠陥が個別の問題ではなく、リポジトリ全体の表出的構造と内部的構造の不一致であると判明したためである。以後は構造の全面再設計とその移行が主線になり、MCP roadmap の未了分は移行の中へ吸収した。

現在は構造移行の第 5 段の途中である。

## 2. 完了して commit した内容

```
3897dce refactor: OCI image の宣言と検査を images unit へ移す
11a8d9f refactor: shell の実体と test を所有する unit へ移す
721564a refactor: command の契約と小さい責務を unit へ移す
4b090e3 refactor: repo 自身の検証を quality unit へ移す
e757dd3 refactor: ADR を git から外し commit に Why を書けるようにする
731ee9d docs: 文書の種別と読み手を定め機械検証に固定する
10d83de docs: 文書の型と配置を定義し参照切れを検査する
074eb17 docs: MCP session lifecycle の判断を記録
12e99f1 feat: doctor に MCP 資源観測を追加
7390bfe fix: MCP session の保持時間と FD 上限を固定
6df735f fix: agentgateway の downstream SSE lifecycle を修正
663d4f8 test: agentgateway の session lifecycle 回帰を固定
```

### MCP session 安定化 (663d4f8 / 6df735f / 7390bfe / 12e99f1 / 074eb17)

agentgateway 1.3.1 の downstream SSE が keepalive を持たず、Claude Code が約 300 秒で GET を閉じて再接続するたびに新しい session と全 stdio target が積み上がっていた。`sessionTtl = 4h` と systemd 既定の `LimitNOFILESoft = 1024` が重なり、journal に `Too many open files` が 1 日で 7798 件記録されていた。

修正は `pkgs/agentgateway/mcp-downstream-lifecycle.patch` にある。test を先に置き、`doCheck` と `checkFlags = [ "downstream_lifecycle_" ]` で package build 時に 3 つの回帰を走らせる。

- pending SSE は 15 秒ごとに SSE comment frame を返す
- response body が生存する GET stream は idle TTL を超えても reap しない
- idle は body の終了時刻から数える。明示 DELETE は即座に削除する

`sessionTtl` を 30 分へ戻し、`LimitNOFILE = "4096:4096"` を暫定の封じ込めとして置いた。doctor に `active.mcp.resources` を追加し、`TasksCurrent` / `MemoryCurrent` / `MemorySwapCurrent` / `LimitNOFILE` / `LimitNOFILESoft` と `MainPID` の FD 数を観測する。期待値を持つのは FD 上限だけで、その値は systemd 宣言から導く。

計画から変えた点が 2 つある。`SessionEntry.last_access` は `std::time::Instant` で `tokio::time::advance` が効かないため、reap の test は `idle_ttl = Duration::ZERO` で期限切れを作る。resource policy に metrics timeout を置かない。資源値は unit 検査と同じ `systemctl show` に相乗りするので `systemTimeoutSeconds` で既に bounded である。

### 文書の再構成 (10d83de / 731ee9d / e757dd3)

文書を学習・手順・参照・説明の 4 種別に分け、各文書が冒頭に読み手を書く。現時点で学習の文書は無い。決定の記録は 4 種別と直交する別の軸である。

環境の観測 (`docs/audits/`)、実装計画 (`docs/superpowers/`)、決定の記録 (`docs/adr/`) を `.gitignore` へ入れて追跡対象から外した。file はローカルに残る。

記録の置き場を次のとおり固定した。

| 媒体 | 記録するもの |
|---|---|
| コード | How |
| テストコード | What |
| コミットログ | Why |
| コードコメント | Why not |

ADR が必要に見えるときは、コミットログが Why を持っていない徴候として扱う。`commit-msg` hook を body 許可へ更新した。subject が空でないことと、body があるとき 2 行目が空行であることだけを検査する。行数は制限しない。

### 構造移行の第 1-4 段と第 5 段の一部

第 1 段で `structure-layer-names` を置いた。層の file 名 8 つを 1 箇所に定義し、unit の直下はその 8 つか子 unit だけを許す。

第 2 段で `collectUnits` と `mergeChecks` を `flake.nix` に入れた。`module.nix` / `package.nix` / `checks.nix` / `impl/` のいずれかを持つ directory を unit と判定し、再帰で子 unit も拾う。各 unit の `module.nix` を NixOS module へ、`checks.nix` を flake の checks へ写像する。check id が重複したら評価時に throw する。

第 3 段で `quality` unit へ repo 自身の検証 10 件を移した。第 4 段で `commands` 契約と `cleanup` / `git` / `accounts` / `bootstrap` を移した。第 5 段で shell library と test を所有 unit へ振り分け、`images` unit を完成させ、`sops` unit を作った。

`flake.nix` は 1461 行から縮小中。`modules/commands.nix` は 640 行から 356 行になった。

## 3. 未 commit の変更

`sops` unit の作成である。`git status` に出る。検査は通っている状態まで持っていったが commit していない。

```
secrets/          暗号化データのみ。unit ではない
  .sops.yaml
  secrets.yaml
sops/             unit
  module.nix checks.nix impl/ tests/ fixtures/
```

commit する前に `nix flake check -L` の結果行を確認すること。commit には `--no-verify` が要る (理由は 5 節)。

commit message の案。

```
refactor: SOPS の宣言と検査を sops unit へ移す

secrets/ は enroll が「.sops.yaml と secrets.yaml だけを含む」
ことを検査する data 置き場で、unit にすると不変条件を壊す。
利用者が打つ secret 編集 path も変えない。unit は sops と
名乗り、data は repo 直下に残す。
```

## 4. 設計の正本

`docs/superpowers/plans/2026-07-31-repository-structure-redesign.md` にある。追跡対象外なのでローカルにしか無い。

### 構造の骨子

責務を最上位の軸にし、層は各 unit の中で file 名によって表す。同じ file 名が全 unit に現れるため、tree を横に見れば層が分かる。

| 層 | 定義 | 付随物 |
|---|---|---|
| 宣言 | `module.nix` | `assets/` |
| package | `package.nix` | `package/` |
| runtime | — | `impl/` |
| 検証 | `checks.nix` | `tests/`、`fixtures/` |

持たない層の file は作らない。持つ場合の名前だけを固定する。名前を足すのは決定であり、その commit の body に理由を書く。

unit をまとめる中間 directory は作らない。責務を repo 直下に置く。子になるのは、親が宣言する契約の実体であり、その契約なしには独立した責務を持たないときである。

`flake.nix` は unit の収集と flake output への写像だけを持つ。全 unit の統合結果である `nixos-toplevel` だけが flake 所有の check である。

検証の期待値は宣言から導出し、転記しない。unit 間の依存は宣言し、循環させない。層をまたぐ機構は、その種類を宣言する unit が持つ。

### 目標の tree

```
.
├── flake.nix flake.lock README.md LICENSE statix.toml .gitignore
├── docs/
├── secrets/           暗号化データのみ
├── accounts/ bootstrap/ cleanup/ commands/ git/ quality/
├── system/ toolchain/ telemetry/ sonarqube/
├── images/ sops/ rebuild/ doctor/
├── clis/
│   ├── module.nix impl/ assets/{AGENTS.md,agents/,skills/} checks.nix
│   └── claude/ codex/ opencode/ antigravity/
└── mcp/
    ├── module.nix package/ impl/ checks.nix
    ├── gateway/
    └── targets/{codex,context7,crawl4ai,github,memory,playwright,probe,searxng}/
```

### option namespace

| 接頭辞 | 層 |
|---|---|
| `my.<unit>` | 宣言 |
| `my.artifacts` | 生成 |
| `my.contract` | 検証と unit 間の契約 |

`my.contract` は導入済みで、`images` と `sops` が使っている。`my.doctor` → `my.contract.doctor`、`my.configArtifacts` → `my.artifacts`、`my.ociImages` → `my.images` の改名は第 10 段。

## 5. 実機の状態

**今日の commit はどれも実機に入っていない。**

| 項目 | 稼働中 | commit 済みの source |
|---|---|---|
| `sessionTtl` | `4h` | `30m` |
| `LimitNOFILESoft` | 1024 | 4096 |
| agentgateway patch | なし | keepalive と stream guard |
| doctor の資源観測 | なし | `active.mcp.resources` |
| commit-msg hook | body 禁止 | body 許可 |

`dotfiles-rebuild` を打っていないため generation が切り替わっていない。hook が旧版なので、body 付き commit には `--no-verify` が要る。

依頼者の方針は「移行準備が完全に済んでから実機」である。rebuild は agentgateway を restart し、同じ WSL で動く他セッションの MCP 接続を切る。実行前に確認すること。

最後の実測 (2026-07-31 09:32 UTC、service uptime 7 時間 26 分) では fdCurrent 21、TasksCurrent 17、MemoryCurrent 507 MB、子 process 0、直近 1 時間の EMFILE 0 件。朝の障害時は子 100、Tasks 979、5.09 GB だった。蓄積は接続数に比例するので、AI CLI が繋ぎ直せば再び増える。

## 6. 次にやること

### 第 5 段の残り

`rebuild` と `doctor` の宣言移設。`modules/commands.nix` の残り 356 行の大半である。

`rebuild` は実装 3085 行、`wsl-restart-required` 202 行、検査 8 件 (`rebuild-attempt` `rebuild-entrypoint` `rebuild-routing` `active-publication` `atomic-publication` `gc-root-observer` `preparation-parent-evidence` `wsl-restart-policy`)。impl/lib と tests と fixtures は移設済み。

`doctor` は実装 1355 行、manifest 生成、検査 2 件 (`doctor-manifest-contract` `doctor-runtime`)。tests は移設済み。`my.contract.images` と `my.contract.secrets` を読む。

両者は manifest schema で相互に参照する。`doctor` が manifest を所有し `my.contract.doctor` として公開、`rebuild` がそれを読む形にすれば、宣言された契約になる。Nix の評価では循環しない。参照するものが異なるためである。

### 第 6 段以降

```
6  clis と share/ 移設
7  mcp と endpoint 分離。roadmap の未了分をここで実現
8  system 移設、modules/ pkgs/ scripts/ 削除
9  toolchain / telemetry / sonarqube 新設、LSP roster
10 option namespace 整理
11 文書を新 tree へ
```

### 第 7 段が吸収する MCP roadmap の未了分

endpoint を 3 つに分ける。id から service 名と runtime directory と config artifact id と doctor check id を導出し、default にも例外を作らない。

| endpoint | service | runtime directory | target |
|---|---|---|---|
| default | `agentgateway-default.service` | `/run/agentgateway-default` | context7 crawl4ai github-* memory probe searxng |
| playwright | `agentgateway-playwright.service` | `/run/agentgateway-playwright` | playwright |
| codex | `agentgateway-codex.service` | `/run/agentgateway-codex` | codex |

transport を tagged union にする。`transport.stdio.command` と `transport.http.url` のどちらか一つだけを持ち、upstream schema key への変換は `mcp/gateway/module.nix` だけが持つ。

target ごとに一つの常駐 HTTP service を持つ。native HTTP mode がある target に bridge を使わない。

doctor check id は `active.mcp.<endpoint>.<phase>` と `active.mcp.<endpoint>.target.<target>` に固定する。第三 segment は常に endpoint id とする。

config artifact id は `mcp/endpoint/<endpoint>/<name>` と `mcp/target/<target>/<name>` の二文法に固定する。

port は endpoint と front を一つの列に集め、`mcp/module.nix` の assertion で一意性を検査する。

### 第 9 段が入れるツール

判定基準は「環境に置くのは全 project 横断で agent が使うもの。project 固有の設定や対象を要するものは devenv が持つ」である。

LSP は Claude Code 組み込みで、plugin の `.lsp.json` に server を登録する。binary は Nix が宣言する。roster を `clis/module.nix` が持ち、登録形式を各 CLI が持つ。

| 言語 | 実装 | 使用量 (生成物を除いた file 数) |
|---|---|---|
| C# | `roslyn-ls` | 88,922 |
| TypeScript | `typescript-go` の `tsgo --lsp --stdio` | 35,780 |
| Java | `jdt-language-server` | 11,543 |
| Python | `ty` + `ruff` | 3,860 |
| Nix | `nixd` | 116 |
| Bash | `bash-language-server` | 63 |
| Rust | `rust-analyzer` | 625 |

`tsgo` は nixpkgs が `0-unstable-2026-05-20` で TypeScript 7 RC より古いが、`initialize` に応答することを実測で確認済み。`ty` は beta だが 1.0 での入れ替えを避けるため今から採る。

SQL は採らない。`sqls` は補完に DB 接続設定を要し、接続先が project ごとに変わる。`yaml-language-server` と `vscode-langservers-extracted` と `marksman` も限界効用が小さいため採らない。

`toolchain/` に `ast-grep`、`semgrep`、`actrun`、`apm`。`telemetry/` に OpenTelemetry collector。`clis/checks.nix` に `waxa` で skill を評価。`sonarqube/` に server と DB を常駐で。

採用しないもの。Sentry は self-host の最小要件が 16 GB RAM と 16 GB swap で available を食い切る。CodeQL CLI は private repository の解析に GitHub Code Security の license を要し、DB 構築が実質 compile で C# 88,922 file では agent の loop に載らない。Schemathesis は解析対象の schema が project ごと。agent-browser は Playwright が操作、Chrome DevTools が観測を持つ構成で責務が薄い。

保留するもの。Chrome DevTools MCP は常駐 HTTP front 移行後に `mcp/targets/chrome-devtools/` へ。probe は LSP 導入後に削除を判定する。`probe_grep` は既に gateway で deny 済みで、`probe_search_code` は LSP の参照検索と built-in Grep と ast-grep に、`probe_extract_code` は Read の範囲指定に覆われる。

Microsoft APM は置き換えに使わず `toolchain/` の package として持つ。`clis/` の責務のうち APM が代替できるのは user scope の配備だけで、`/etc` の managed settings と binary の取得と固定と LSP 登録と doctor 契約は残る。user scope へ入れると Nix store を正本とする配備と `apm.lock.yaml` を正本とする配備が同居し、doctor の照合も APM 配備物には届かない。project scope はこの repo が持たない層なので、そこは APM が担う。

## 7. 移行で繰り返し踏んだ故障

path の故障が 4 種類あった。いずれも事前監査を抜けて `nix flake check` が捕まえた。

| 種類 | 実例 |
|---|---|
| Nix の相対 path | `import ./modules/nix-caches.nix` が移動後に `quality/modules/...` を指す |
| 起点の違う相対参照 | `modules/secrets.nix` の `./user/git/identity.conf` を `modules/user/git` の grep で見落とす |
| script 内の runtime path | `bootstrap.sh` の `source $(dirname $0)/lib/atomic-file.sh` |
| repo root 起点を unit 内に書く | `secrets/fixtures/x` を unit 内に書き `secrets/secrets/fixtures/x` に解決させた。4 回繰り返した |

対処として次を規則にした。

**unit 内の file が path を書くときは起点を混ぜない。自 unit の資材は `./` 起点、他 unit と repo root は `${self}/` 起点だけを使う。**

移設のたびに移動元へ未使用束縛が残り、`deadnix` が拾う往復が発生した。`statix` も `inherit` 化の指摘を出す。full check は 10 分かかるので、block 移設の直後に次を直接叩いてから full check に入ること。

```bash
nix build .#checks.x86_64-linux.structure-layer-names
nix shell nixpkgs#statix --command statix check --config . --format errfmt .
nix shell nixpkgs#deadnix --command deadnix --fail .
```

`statix` は `--format errfmt` で位置が一行で出る。既定の box 描画出力を色除去して読もうとすると位置が取れない。

新規 file は `git add` してから評価すること。flake は追跡 file しか見ない。これで 2 回詰まった。

移設のたびに `nix eval --raw .#... ` と `nix eval --raw "git+file://$PWD#..."` を比べ、store path が一致することを確認した。`dotfiles-cleanup`、`dotfiles-sync-images`、`dotfiles-sops-enroll` の 3 つで一致を実測済み。構造を変えても生成物は変えないという原則の担保である。

## 8. 判断を変えた箇所

同じ論点で複数回結論を変えたものがある。最終形と決め手を書く。

**structure の適用範囲。** architecture-standard の `structure/` をこの repo へ適用しようとしたが、依頼者から「思想面を参照しろと言っているのであり、layout・structure を適用しろとは言っていない。それは実際のプログラムプロジェクト用でこのリポジトリとは役割が異なる」と指摘された。`principles/` と `process/` の思想は適用し、`structure/skeleton.md` の root 構成は適用しない。

**`units/` 中間 directory。** 一度は `units/<unit>/` を提案したが、「`units/` の存在価値がわからない」との指摘で撤回した。`docs/` も source なので「units は source、直下は非 source」という私の正当化が成立していなかった。責務を repo 直下に置く。

**Microsoft APM。** 検索 snippet だけで「置き換え候補」と断じ、次に「user home には書かない」で非重複と断じ、どちらも一次資料を読み切っていなかった。最終判断は 6 節にある。

**`secrets/` の扱い。** 「unit の位置なので移動不要」→「`assets/` へ移す、利用者 path が変わる」→「data 置き場のまま、unit 名は `sops`」と 2 回変えた。決め手は `sops-enroll.sh:136` が「この directory は `.sops.yaml` と `secrets.yaml` の 2 つだけを含む」を検査していること、および設計制約「利用者が打つ command は同じものを維持する」である。

`sops` という unit 名は責務ではなく機構の名前で、命名規則から外れる。`secrets` は data 置き場と衝突する。より良い名前があれば変えてよい。

## 9. 環境と規律

同じ WSL で他セッションが並行して動く。working tree、git index、稼働 service、MCP gateway の session はすべて共有である。実際にこのセッション中、別セッションの commit が同じ branch へ入り、履歴の書き換えも起きた。

- 長時間 uncommitted な変更を working tree に置かない
- `git add -A` と `git commit -a` を使わず、触った path だけを明示的に stage する
- `dotfiles-rebuild` と service restart は他セッションの MCP 接続を切る。実行前に確認する
- 作業再開時は `git log` で自分以外の commit が入っていないか先に確認する

git 履歴の全面改善が別途予定されている。既存履歴は subject-only で Why を持たない。構造改善の完了後に着手する予定であり、それまで過去の commit を書き換えない。今日ローカルに残した `docs/adr/` 18 件は、その改善で Why を commit body へ、Why not を code comment へ移すときの材料になる。

MCP gateway の tool はこのセッションの後半で client 側が切断された。gateway 自体は HTTP 200 を返し service も active だったので、復旧には session 再起動が要る。切断中の Web 調査は `WebSearch` と `WebFetch` で行い、一次資料を直接取得する形で規約の意図を満たした。

## 10. 検証の状態

`nix flake check -L` は `sops` unit の変更を含めて通っている。check は 30 件。

固定済みの制約と未固定の制約は `docs/reference/verified-constraints.md` に列挙してある。`docs-constraint-coverage` が、一覧と実際の check 集合が双方向で一致することを検査する。check を足したら同じ表へ載せる。

未固定として記録してあるものが 3 つある。文書の種別が混ざっていないこと、参照文書が宣言の値を転記していないこと、一つの責務の宣言と実装と test が同じ場所にあることである。

検査を足したら、緑を見る前に赤を見ること。検査対象を意図的に壊し、期待した message で落ちることを確かめてから戻す。この手順で、何も検出しない検査を 1 件と、最初の失敗が残りを隠す構造を 1 件見つけた。
