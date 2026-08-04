# 機械検証に固定した制約

**読み手:** どの制約が自動で守られ、どれが守られていないかを調べたい人。作業中に読む。

重要な制約は文書やレビューの指摘で運用せず、build で落ちる形に固定する。この表は固定済みの制約と、その検証手段を列挙する。監査はこの表を照合の対象にする。

`nix flake check` が全件を実行する。個別に走らせるときは `nix build .#checks.x86_64-linux.<検証>` を使う。

## 宣言と実状態

| 制約 | 検証 |
|---|---|
| option の接頭辞が宣言した unit の名前と一致する | `option-namespace` |
| 適用の入口が working tree と WSL 再起動を確かめてから nixos-rebuild を呼ぶ | `rebuild-entrypoint` |
| 検証対象を別の登録簿から取らず宣言した unit から導く | `doctor-coverage` |
| 登録簿が空にならない | `registries-non-empty` |
| 契約に unit 外の読み手がいる | `contract-has-reader` |
| 宣言した recipient と暗号文の recipient が一致し host 鍵と recovery 鍵が揃う | `sops-policy` |
| home に置く secret が user 所有の 0600 である | `sops-secret-file-mode` |
| loopback port を二人以上が bind しない | `loopback-port-single-owner` |
| container の argv が語彙・所有・loopback の contract に収まる | `container-argv-contract` |
| container を起こすのは ExecStart だけ | `container-exec-content` |
| unit が他 unit を契約経由でだけ参照する | `unit-boundary-name-only` |
| generation が無い状態から age 鍵を配って rebuild へ渡し、鍵 path が宣言と一致する | `bootstrap-age-key` |
| 宣言した systemd service が listener か portless として登録される | `service-listener-registry` |
| front の wrapper が自分の bind を決めない | `mcp-front-wrapper-bind` |
| front の wrapper が条件付き exec で起動不能にならない | `mcp-front-starts` |
| PATH 上の実行ファイル名を二人以上が所有しない | `toolchain-single-owner` |
| 宣言した language server の command が package に存在する | `lsp-command-present` |
| 上流 release から作った binary が空環境で起動する | `toolchain-binary-runs` |
| LSP roster と各 CLI の登録が一致し、拡張子が衝突しない | `lsp-registration` |
| telemetry collector の config が妥当で receiver が loopback に閉じる | `telemetry-collector-config` |
| SonarQube の server と DB が同じ credential を見て DB port を公開しない | `sonarqube-topology` |
| 生成 config artifact が登録簿に載り、宣言の変更に追随する | `artifact-registry` |
| 生成 config artifact が配備先の source と一致する | `cli-artifact-contract`、`gateway-artifact-contract` |
| gateway が全 target へ HTTP で接続し子 process を作らない | `gateway-front-contract` |
| front が宣言した port で loopback に listen し書き込み領域を持つ | `mcp-front-contract` |
| Playwright の front が生成物を runtime directory に閉じる | `playwright-front` |
| gateway が wildcard へ bind するので通信を cgroup で loopback に限る | `gateway-artifact-contract` |
| backend の待ち受け port が配備される argv の publish と一致する | `agentmemory-config`、`searxng-settings` |
| 生成 config artifact が構文として妥当である | `config-syntax` |
| OCI image の宣言が container と pull 方針に一致する | `oci-image-contract` |
| MCP target 名が互いに prefix 衝突しない | `nixos-toplevel` (`mcp/module.nix` の assertion) |
| image id が container を一意に指す | `nixos-toplevel` (`images/module.nix` の assertion) |
| 全 module から system closure を評価できる | `nixos-toplevel` |

## runtime の振る舞い

| 制約 | 検証 |
|---|---|
| MCP session が active な GET body の間 reap されない | `agentgateway-session-lifecycle` |
| WSL 再起動の要否を判定できる | `wsl-restart-policy` |
| agentmemory の credential が環境ファイル経由で渡る | `agentmemory-env` |

## 文書

| 制約 | 検証 |
|---|---|
| 文書間と source への参照が切れていない | `docs-links` |
| 文書が名乗る path が実在する | `docs-path-labels` |
| 手順、参照、説明の各文書が読み手を明示している | `docs-reader` |
| この一覧が実際の check 集合と一致する | `docs-constraint-coverage` |

## 構造

| 制約 | 検証 |
|---|---|
| unit の直下が層の file 名か子 unit だけである | `structure-layer-names` |

## 形式

| 制約 | 検証 |
|---|---|
| Nix の整形 | `nixfmt` |
| Nix の未使用束縛 | `deadnix` |
| Nix の慣用 | `statix` |
| shell の静的検査 | `shellcheck` (shebang を持つ file が対象、fragment は `writeShellApplication` が build 時に見る) |
| GitHub Actions workflow の妥当性 | `actionlint` |
| devenv と direnv を home だけが所有し、binary cache が一度だけ登録される | `development-tool-ownership` |

## 固定できていない制約

次は現在レビューでしか検出できない。検証手段を足すまで、この節に残す。この節には check 名を書かないため、`docs-constraint-coverage` の網羅検査は届かない。項目の古さは、検証手段を足すときに手で確かめる。

- 文書の種別が混ざっていないこと。読み手の明示は検査するが、内容が手順と説明を混ぜていないことは検査していない。
- 参照文書が宣言の値を転記していないこと。roster や件数の転記は検査していない。
- 一つの責務の宣言、実装、test が同じ場所にあること。配置の規約を検査していない。
- 転記した期待値が宣言と同時に書き換わらないこと。`mcp/checks.nix` の `expectedNetworkFronts` は意図した二重鍵で、`needsNetwork` を足すだけでは通らず diff に必ず現れる。ただし両方を同時に書き換えた場合は通る。
- front が実際に loopback へ bind すること。起動 command に bind 先が現れることは検査するが、process が本当にその address で listen するかは実機でしか分からない。agentgateway が config に書かない管理 listener を三つ開いていた実例がある。
- front が loopback の外へ出るかどうかの宣言が実体と一致すること。`needsNetwork` の集合は検査で固定するが、宣言が実装の挙動と合っているかは上流を読むしかない。searxng の `web_url_read` が `SEARXNG_URL` を経由せず引数の URL へ出る実例がある。
- 通信制限による失敗が観測できること。`IPAddressDeny` の遮断は timeout として現れ、unit は active のままなので doctor の unit 検査は緑を保つ。tool を呼ぶまで表面化しない。
- container が image 由来で expose する port を把握していること。宣言は publish する port しか持たない。crawl4ai の image は内部 valkey の 6379 を expose しており、`dotfiles-backends` network 上の他 container から到達する。
- 宣言した port が実機で空いていること。検査は宣言どうしの衝突しか見ない。他 project の process が先に取っていると front は起動できず、`Restart=always` で再試行を続ける。
- unit の依存が設計の依存表に載っている組だけであること。依存の向きを検査していない。
