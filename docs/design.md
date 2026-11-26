# 設計

このrepositoryが何を持ち、何を持たないか、なぜそう決めたかを書く。手順は[運用](operations.md)にある。

## 目的

実案件の作業を邪魔せずに、再現できる開発機と、agentの能力を引き出す設定を供給し、その変更を速く安全に行えること。

agentの完了と品質の判定は、harness（OMP）、各projectの検査、利用者の指示に任せる。環境は作業の途中にも終わりにも介入しない。
許容しない失敗は次のとおり。作業中のsessionの停止や妨害、hostの凍結、秘密情報の漏洩、利用者データの消失、配備で前の状態へ戻れないこと、利用者が決めたmodelの割当やstandardの扱いを無断で変えること。

## 持つもの

| 領域 | 場所 | 内容 |
|---|---|---|
| 開発機 | `hosts/`、`workstation/` | NixOS-WSL、nix、user、locale、font、storage、memoryの保護、Docker、適用（`dotfiles-rebuild`）、点検（`dotfiles-doctor`） |
| 秘密情報と身元 | `secrets/`、`identity/` | sops-nix、GitHub accountとGitの身元 |
| 開発道具 | `toolchain/` | CLI、language server、Gitの設定とglobal hook |
| agentの設定 | `agents/` | clientのbinaryと起動wrapper、OMPの設定、MCP server、方針（`AGENTS.md`、`RULES.md`）、skill、案件票（`dotfiles-agent-brief`） |
| 知識 | `knowledge/` | Hindsight（記憶）、記憶の実行環境とMCP、日誌、訂正の収穫 |

`agents/`の方針とlocal skillはNixの外の本文で、`~/.omp/agent`などからcheckoutへlinkする。編集は再buildなしで次の読込から効く。
upstreamのskillはflake inputの固定sourceから配る。architecture-standardのskillだけは、利用者の「常に最新・revisionを固定しない」方針に従い、公開版を日次で取得するcloneから配る。rebuildは標準の作業状態に依存しない。

## 持たないもの

次は過去に持っていたが、目的に対して害が大きいと分かったので持たない。数字は2026-10-12〜11-26のsession記録と実機の計測による（計測の記録は追跡外の`~/.local/share/dotfiles-wsl-archive/redesign-20261126/`）。

- **session終了の検証gateとT1証跡**: 再指示4,198件、そのうち4,077件は作業のない応答。gateを満たすこと自体が目的になった事例があり、欠陥を捕まえた事例は見つからなかった。検証は各projectのcommandを直接実行し、依頼の成果ごとに報告する。
- **資源の入場制御**（acceptance/deep、`capped-run`、`workload-run`）: 未起動140回、待ち合計47.7時間。hostは cgroup の上限と systemd-oomd で守り、仕事を待たせない。
- **全repo共通のpre-push検証**: pushに1,000秒〜3時間かかった。repo固有の`.githooks`は、利用者が信頼を与えたrepoで従来どおり動く。
- **session supervisor、GC rootの保護、session台帳**: 起動1回に約10秒と321 process。OMP 19の共有daemonを1つのsessionの終了で殺す所有の衝突もあった。
- **MCP gatewayと常駐front**: OMPがserverを必要時に起動し、共有し、5分で止める。常駐約0.85 GBを使わない。
- **registry群**（capability、managed artifact、health observation、CLI）と437項目のdoctor: 消費者のいない間接層と、常に失敗する警報だった。
- **利用していないclientのadapter**: Claude Code、Codex、OpenCode、Antigravityは、OMPが使えないときの予備としてbinary、方針、skill、日次の更新だけを持つ。subagent定義、hook、MCPの設定は持たない（2026-10-27〜11-26に利用者が使ったsessionは0件）。旧構成がCodexのために入れていたbubblewrapは、codex 0.171のsandboxがPATHに無くても書込みを制限することを確かめたので持たない。
- **Playwright MCP**: OMPは標準browserがあるsessionでPlaywright MCPを読み込まず、解除の方法は標準browserを無効にすることだけである。旧構成ではgatewayの名前の陰で読み込まれていた（直近30日に案件のsessionで469回）。画面の操作は標準browserへ、Playwrightで書く回帰testはprojectのPlaywright Testへ寄せる（`docs/tools.md`）。
- **停止したtest containerの定期回収**: 回収の対象は停止したものだけで、2026-11-16〜26の41回の記録に回収したものは無かった。testcontainers-rsが残すのは主に動いたままのcontainerで、この回収では消えない。後片付けはprojectのtest（`watchdog` feature）が持ち、`dotfiles-doctor`は6時間より古いものを示すだけにする。
- **後片付けのcommand**（`dotfiles-cleanup`）: Home Managerの退避の衝突は`home-manager.overwriteBackup`、VS Code Serverの古い版はVS Code自身が片付ける。
- **agent sessionごとの環境**（専用の`TMPDIR`、共有の`CARGO_HOME`と`XDG_CACHE_HOME`、checkoutの外のCargo build-dir、`nix build`の結果linkを作らないshim）: session runtimeの分離とGCを前提にした補正で、既定の場所なら共有も回収も作業木の寿命と一致する。

新しい仕組みを足す前に、同じ失敗を起こさない構造（所有の明確化、不要な状態の削除）を先に考える。検査を足す場合は、過去の実際の失敗を再現して落ちることを確かめる。

## 起動から終了まで

```text
Orcaのpane → bash -l → omp（wrapper）→ systemd-run --user --scope（agents.slice）→ OMP
```

- wrapperはscopeへ入れるだけで、終了時に子processを殺さない。scopeはmemoryの会計と上限のためにある。
- turn、session、subagent、bash job、取消、再開（`omp --resume`）はOMPが持つ。
- OMPの共有daemon（LSP、MCPを持つ）は最初に起動したsessionのscopeに入るが、そのsessionが終わっても止まらない。
- clientが終わった後もscopeに残ったprocessは`dotfiles-doctor`が示す。MSBuildのnode再利用は環境変数で止めている（14時間残った例がある）。
- 過負荷では`agents.slice`の`MemoryMax`によりそのslice内でOOMが起き、systemd-oomdがpressureの高いcgroupを止める。hostは止まらない。
- memoryの上限はどの層（`user.slice`、user manager、`agents.slice`、containerのslice）も`MemoryMax`だけにし、`MemoryHigh`を置かない。2026-11-26の計測で、`agents.slice`の30.4 GiBのうち20.3 GiBは回収できるpage cacheで、high到達は起動後約23時間で`user.slice`が3,414,763回、`agents.slice`が2,285,613回、`agents.slice`のmemory PSIはfull avg60で約11%だった。`MemoryHigh`は超過分に応じてprocessを待たせるため、cacheの量でagentを減速させていた。守りたい失敗（2026-11-01のswap thrashによる停止）は、`MemoryMax`（到達時はcacheから回収し、回収できなければその層の中でOOM）、小さいswap上限、oomdで防ぐ。

## 記憶と知識

Hindsightの検索は機能するが、使い方に問題があった（古い決定が新しい決定より上位に返る、毎回の注入に3〜5秒かかる、必ず守るべき決定を確率的な検索に置いていた）。現在の使い方は次のとおり。

- 必ず効かせる決定は文書に置く。利用者の方針は`agents/AGENTS.md`、projectの決定はそのprojectの文書。
- 記憶の検索はsessionの最初の依頼と、明示的な要求のときだけ行う。
- 決定を保存するときは、上書きされる古い記憶を失効させる。
- agentが作業中に気付いた知見はその場で保存し、見過ごした知見は日誌の事後抽出が拾う。日誌は記事（agent-journal）と記憶の両方へ書く。

## 自身の検証

`nix flake check`が、format、lint、shellcheck、hostの評価、残したscriptの振る舞い検査を実行する。CIも同じ。
配備の成立は、build、`dotfiles-rebuild`、`dotfiles-doctor`、新しいsessionでの方針・skill・MCP・LSPの利用で確かめる。検査の合格は、利用者の仕事が良くなったことの証拠にはならない。
