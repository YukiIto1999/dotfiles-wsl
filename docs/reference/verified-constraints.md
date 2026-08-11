# 機械検証に固定した制約

**読み手:** どの制約が自動で守られ、どれが守られていないかを調べたい人。作業中に読む。

重要な制約は文書やレビューの指摘で運用せず、build で落ちる形に固定する。この表は固定済みの制約と、その検証手段を列挙する。監査はこの表を照合の対象にする。

`nix flake check` が全件を実行する。個別に走らせるときは `nix build .#checks.x86_64-linux.<検証>` を使う。

## 宣言と実状態

| 制約 | 検証 |
|---|---|
| unit directory の各 segment が小文字 kebab-case である | `structure-unit-directory-names` |
| option の接頭辞が宣言した unit の名前と一致する | `option-namespace` |
| repository の Nix source に旧 option namespace と global helper injection が残らない | `dotfiles-option-namespace` |
| 適用の入口が working tree と WSL 再起動を確かめてから nixos-rebuild を呼ぶ | `rebuild-entrypoint` |
| doctor が owner の observation registry を欠落なく key 順に投影し、17 種類の observation kind を一つずつ汎用 probe に対応させ、旧 owner 固有 inventory と状態機械を持たない | `doctor-coverage` |
| 17 種類の observation kind の pass、warn、fail、resource、restart 集約と、protocol の不正、過大出力、非ゼロ終了、timeout を固定 message と終了 status に反映する | `doctor-runtime` |
| WSL 専用 zram lifecycle、journald、標準 fstrim と service 非依存が宣言どおりである | `host-stability-contract` |
| 登録簿が空にならない | `registries-non-empty` |
| runtime observation registry が 17 種類の observation kind、必須 field、path と ID、閾値、専用 command package を型で制限し、定義位置を owner と照合する | `observation-contract` |
| required roster が空または未知の ID を含む構成を拒否し、通常構成と variant の system closure を評価できる | `required-roster-negative-eval` |
| 宣言した recipient と暗号文の recipient が一致し host 鍵と recovery 鍵が揃う | `sops-policy` |
| home に置く secret が user 所有の 0600 である | `sops-secret-file-mode` |
| loopback port を二人以上が bind しない | `loopback-port-single-owner` |
| container の argv が語彙・所有・loopback の contract に収まる | `container-argv-contract` |
| container を起こすのは ExecStart だけ | `container-exec-content` |
| container backend helper が network 依存、再起動方針、publish 順序、依存、mount、環境 file、image 取得方針を一つの形で生成する | `container-backend-contract` |
| container service contract から service、restart、image、health、roster、BuildKit GC の observation を漏れなく導き、追加と削除に追随する | `container-runtime-observation-contract` |
| BuildKit GC の保持量、timer、prune 引数が固定され、Docker と backend が GC に依存しない | `docker-buildkit-gc-contract` |
| 共通 container helper の import が一件以上存在し、`containers` 以外の unit は import、readFile、別構文で参照しない | `unit-boundary-name-only` |
| MCP unit が OCI、secret template、同名 backend の secret と service contract を所有しない | `mcp-no-container-ownership` |
| host の固定 provider roster と target の provider 集合が通常評価と variant 評価で完全一致する | `mcp-provider-roster` |
| target の provider、port、probe、通信方針、backend unit が固定 fixture に一致する | `mcp-target-contract` |
| provider 欠落と追加、ID と port の衝突、probe と通信方針の drift、front dependency と sandbox の欠落を変異入力で拒否する | `mcp-contract-mutations` |
| repository-owned global module argument がなく、mutation fixture の定義元を unit の最長 path prefix で解決する | `mcp-source-boundary` |
| MCP gateway observer が initialize、session ID、tools/list、target ごとの tools/call を有界に実行し、normalized envelope 以外の raw 出力を doctor へ渡さない | `mcp-gateway-observer` |
| MCP target、front、gateway から service、restart、roster、protocol observation を漏れなく導き、追加、削除、変更、stale entry に追随する | `mcp-runtime-observation-contract` |
| runtime identity fixture が現在の宣言から導いた MCP target port、gateway、container 名と network、secret 名、永続 path に完全一致する | `runtime-identity` |
| generation が無い状態から age 鍵を配って rebuild へ渡し、鍵 path が宣言と一致する | `bootstrap-age-key` |
| 宣言した systemd service が listener か portless として登録される | `service-listener-registry` |
| front の wrapper が自分の bind を決めない | `mcp-front-wrapper-bind` |
| front の wrapper が条件付き exec で起動不能にならない | `mcp-front-starts` |
| PATH 上の実行ファイル名を二人以上が所有しない | `toolchain-single-owner` |
| 宣言した language server の command が package に存在する | `lsp-command-present` |
| 上流 release から作った binary が空環境で起動する | `toolchain-binary-runs` |
| LSP roster と対応 client の登録が一致し、拡張子が衝突しない | `lsp-registration` |
| telemetry collector の config が妥当で receiver が loopback に閉じる | `telemetry-collector-config` |
| telemetry contract から collector service と restart count の observation を導き、service description を対象選択に使わない | `telemetry-runtime-observation-contract` |
| SonarQube の service contract、server と DB の topology、image、volume、環境 file、再起動、secret metadata、provision service と timer が固定値に一致する | `sonarqube-container` |
| SonarQube MCP front は SOPS の poison stub と canary A / B、型付き credential の canary A / B を用いた隔離評価で package spec と target projection を比較し、実 front artifact が runtime password file を読む | `sonarqube-front` |
| 生成 config artifact が登録簿に載り、宣言の変更に追随する | `artifact-registry` |
| 配備先を持つ artifact だけから source と destination の observation を導き、欠落、変更、古い entry を拒否する | `artifact-runtime-observation-contract` |
| host の固定 client roster、提供集合、型metadata、capability、installer、managed file が固定 fixture に一致し、不正な branch field、必須 field 欠落、freeform field、mode 矛盾を変異入力で拒否する | `agent-client-roster` |
| 共通 rules が UTF-8、非空、見出しを持ち、shared と OpenCode の definition frontmatter、Codex TOML、Claude の byte equality が実配備 source で成立する | `agent-definition-rendering` |
| agent の最終 managed file から system、home、seed、artifact の配備を導き、gateway 一件、agentmemory client source、container から agent への逆依存禁止、旧 path と runtime identity の不在、既存物を壊さない seed を検査する | `agent-artifact-contract` |
| seed migration は宣言した command へ既存 config と home を argv で渡し、client 固有の分岐を共通 module に置かない | `agent-config-migration` |
| 生成 config artifact が配備先の source と一致する | `agent-artifact-contract`、`gateway-artifact-contract` |
| gateway が全 target へ HTTP で接続し、front の起動依存と子 process を持たない | `gateway-front-contract` |
| front が宣言した port で loopback に listen し、書き込み領域、backend dependency、通信方針を持つ | `mcp-front-contract` |
| Playwright の front が生成物を runtime directory に閉じる | `playwright-front` |
| Chrome DevTools の front が host の chromium を使い CDP を露出しない | `chrome-devtools-front` |
| gateway が wildcard へ bind するので通信を cgroup で loopback に限る | `gateway-artifact-contract` |
| agentmemory backend の image、設定、mount、環境 file、health、client package が固定値と一致する | `agentmemory-container` |
| agentmemory MCP front の package、port、backend unit が一致し、initialize に応答する | `agentmemory-front` |
| Crawl4AI backend の image、publish、credential option の型、read-only 属性、値、environment file、health contract が固定値と一致する | `crawl4ai-container` |
| Crawl4AI MCP front は SOPS の poison stub と canary A / B を用いた隔離評価で package spec と target projection を比較し、実 front artifact の環境変数と initialize probe の応答を検査する | `crawl4ai-front` |
| SearXNG backend の image、publish、standalone secret、settings template、health contract が固定値と一致する | `searxng-container` |
| SearXNG MCP front の package、port、backend unit が一致し、initialize に応答する | `searxng-front` |
| 生成 config artifact が構文として妥当である | `config-syntax` |
| SOPS secret 宣言から path、owner、group、mode の observation だけを導き、内容と source path を含めない | `sops-runtime-observation-contract` |
| host が有効化した container application と service contract の key が一致する | `container-application-roster` |
| OCI image の宣言が container と pull 方針に一致する | `oci-image-contract` |
| container application の endpoint URL と port が OCI publish、unit が systemd service に完全一致し、health が宣言済み HTTP endpoint を参照する | `nixos-toplevel` (`containers/module.nix` の assertion) |
| MCP provider roster、target ID、port、GitHub account、front 集合が型付き assertion を満たす | `nixos-toplevel` (`mcp/module.nix` の assertion) |
| image id が container を一意に指す | `nixos-toplevel` (`containers/module.nix` の assertion) |
| 全 module から system closure を評価できる | `nixos-toplevel` |
| gateway port を変え、同じ固定 provider roster を使う第二の評価からも system closure を評価できる | `nixos-variant-toplevel` |

## runtime の振る舞い

| 制約 | 検証 |
|---|---|
| MCP session が active な GET body の間 reap されない | `agentgateway-session-lifecycle` |
| agent runtime の package、timer、四つの managed root、client roster と release tree observation が一つの contract から導かれ、wrapper が upstream binary、session metadata、共有 Cargo/XDG cache、共通 project build cache、明示済み環境値、元の終了 status を保つ | `agent-runtime-contract`、`agent-runtime-behavior` |
| agent 内の Nix build が明示 out-link を尊重し、既定では result symlink を作らない | `agent-nix-build-shims` |
| GitHub release installer は API digest、archive の member、論理 size、package-tree の required path を公開前に検査し、隔離環境で probe した single-binary または package-tree を固定 directory descriptor から公開する。相対 link、release 2 世代保持、rollback、並行更新、別 filesystem の visible path も fixture で検査する | `agent-installer-behavior` |
| agent cache GC が allocated bytes を正本にし、不正な managed path を検出すると削除前に失敗し、inactive project cache を先に回収して active session がない場合だけ共有 cache を空にし、再計測する | `agent-project-cache-gc` |
| source、command、環境が完全一致した成功だけを再利用し、raw 環境値を保存しない | `agent-verification-cache` |
| agent resource command と reaper の package、state root、timer が宣言どおりである | `agent-resource-contract` |
| agent が作った worktree だけを登録し、clean、HEAD 不変、未使用の場合だけ隔離と再検査後に回収する | `agent-resource-behavior` |
| WSL 再起動の要否を判定できる | `wsl-restart-policy` |
| agentmemory の credential が環境ファイル経由で渡る | `agentmemory-container` |
| Crawl4AI の API token が user 用 file contract と root 所有の環境ファイルへ分かれる | `crawl4ai-container` |
| SearXNG の standalone secret と settings template がそれぞれ root:root 0400 で配備される | `searxng-container` |

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
| 固定した virtual tree の再帰走査で通常ファイルの `module.nix` だけを unit marker とし、flake の unit ID が source 内の該当 directory と一致する | `unit-module-marker` |
| SonarQube の unit が `containers/sonarqube` と `mcp/sonarqube` にだけ存在し、旧責務 path が実在しない | `structure-responsibility-roots` |
| unit の直下が層の file 名か子 unit だけであり、移動済みの Agentmemory と SearXNG の資産が旧 path に再作成されない | `structure-layer-names` |

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
- 固定 fixture と実装を同じ変更で誤って書き換えないこと。`mcp-target-contract` と `doctor-coverage` は独立 fixture を使うが、意図のレビューは必要になる。
- front が実際に loopback へ bind すること。起動 command に bind 先が現れることは検査するが、process が本当にその address で listen するかは実機でしか分からない。agentgateway が config に書かない管理 listener を三つ開いていた実例がある。
- front が loopback の外へ出るかどうかの宣言が実体と一致すること。`needsNetwork` の集合は検査で固定するが、宣言が実装の挙動と合っているかは上流を読むしかない。searxng の `web_url_read` が `SEARXNG_URL` を経由せず引数の URL へ出る実例がある。
- 通信制限による失敗が観測できること。`IPAddressDeny` の遮断は timeout として現れ、unit は active のままなので doctor の unit 検査は緑を保つ。tool を呼ぶまで表面化しない。
- container が image 由来で expose する port を把握していること。宣言は publish する port しか持たない。crawl4ai の image は内部 valkey の 6379 を expose しており、`dotfiles-backends` network 上の他 container から到達する。
- 宣言した port が実機で空いていること。検査は宣言どうしの衝突しか見ない。他 project の process が先に取っていると front は起動できず、`Restart=always` で再試行を続ける。
- unit の依存が設計の依存表に載っている組だけであること。依存の向きを検査していない。
