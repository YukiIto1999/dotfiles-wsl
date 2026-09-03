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
| WSL 専用 zram lifecycle、journald、標準 fstrim、Nix の容量 reserve、Windows drive と committed memory の観測、service 非依存が宣言どおりである | `host-stability-contract` |
| 登録簿が空にならない | `registries-non-empty` |
| runtime observation registry が 17 種類の observation kind、必須 field、path と ID、閾値、専用 command package を型で制限し、定義位置を owner と照合する | `observation-contract` |
| required roster が空または未知の ID を含む構成を拒否し、通常構成と variant の system closure を評価できる | `required-roster-negative-eval` |
| 宣言した recipient と暗号文の recipient が一致し host 鍵と recovery 鍵が揃う | `sops-policy` |
| home に置く secret が user 所有の 0600 である | `sops-secret-file-mode` |
| loopback port を二人以上が bind しない | `loopback-port-single-owner` |
| container の argv が語彙・所有・loopback の contract に収まる | `container-argv-contract` |
| container を起こすのは ExecStart だけ | `container-exec-content` |
| container backend helper が network 依存、再起動方針、publish 順序、依存、mount、環境 file、image 取得方針を一つの形で生成する | `container-backend-contract` |
| container service contract から service、restart、image、health、roster、Docker build artifact GC の observation を漏れなく導き、追加と削除に追随する | `container-runtime-observation-contract` |
| dangling image と BuildKit cache の回収順序、daemon policy、timer が固定され、Docker と backend が GC に依存しない | `docker-build-artifact-gc-contract` |
| 共通container helperのimportが承認済みCapability実装に限られ、CapabilityからAgentまたはSkillへの逆依存がない | `unit-boundary-name-only` |
| MCP targetのprovider集合がCapability registryから導かれ、通常評価とvariant評価で一致する | `mcp-provider-registry` |
| targetのprovider、server transport、server lifecycle、port、probe、通信方針、backend unitが固定fixtureに一致する | `mcp-target-contract` |
| Codex MCP frontが`agent-session` Capabilityの実行pathを引用して使い、home pathやbinary名を組み立てない | `mcp-codex-client-executable-contract` |
| provider 欠落と追加、ID と port の衝突、probe と通信方針の drift、front dependency と sandbox の欠落を変異入力で拒否する | `mcp-contract-mutations` |
| GitHub account と `github-<account>` target が完全一致し、欠落、追加、改名を拒否する | `github-account-target-contract` |
| repository-owned global module argument がなく、mutation fixture の定義元を unit の最長 path prefix で解決する | `mcp-source-boundary` |
| MCP gateway observer が initialize、session ID、tools/list、target ごとの tools/call を有界に実行し、normalized envelope 以外の raw 出力を doctor へ渡さない | `mcp-gateway-observer` |
| MCP target、front、gateway から service、restart、roster、protocol observation を漏れなく導き、追加、削除、変更、stale entry に追随する | `mcp-runtime-observation-contract` |
| runtime identity fixture が現在の宣言から導いた MCP target port、gateway、container 名と network、secret 名、永続 path に完全一致する | `runtime-identity` |
| generation が無い状態から age 鍵を配って rebuild へ渡し、鍵 path が宣言と一致する | `bootstrap-age-key` |
| 宣言した systemd service が listener か portless として登録される | `service-listener-registry` |
| stdio service lifecycle front の wrapper が自分の bind を決めない | `mcp-front-wrapper-bind` |
| service lifecycle front と native Streamable HTTP front の wrapper が条件付き exec で起動不能にならない | `mcp-front-starts` |
| Zvec-Grep front が native Streamable HTTP endpoint を直接公開し、agent toolset が意味検索だけを公開する | `zvec-grep-front` |
| PATH 上の実行ファイル名を二人以上が所有しない | `toolchain-single-owner` |
| 宣言した language server の command が package に存在する | `lsp-command-present` |
| 上流 release から作った binary が空環境で起動する | `toolchain-binary-runs` |
| Agent Package Manager が宣言した version で起動する | `agent-apm-binary-runs` |
| LSP roster と対応 client の登録が一致し、client ごとの server id 規則と OMP の有効条件を満たし、拡張子が衝突しない | `lsp-registration` |
| telemetry collector の config が妥当で receiver が loopback に閉じる | `telemetry-collector-config` |
| telemetry contract から collector service と restart count の observation を導き、service description を対象選択に使わない | `telemetry-runtime-observation-contract` |
| SonarQube の service contract、server と DB の topology、image、volume、環境 file、再起動、secret metadata、provision service と timer が固定値に一致する | `sonarqube-container` |
| SonarQube MCP front は SOPS の poison stub と canary A / B、型付き credential の canary A / B を用いた隔離評価で package spec と target projection を比較し、実 front artifact が runtime password file を読む | `sonarqube-front` |
| 生成 config artifact が登録簿に載り、宣言の変更に追随する | `artifact-registry` |
| GitHub account roster、暗号化 template、登録 artifact、Git identity の生成先が typed contract と一致する | `account-deployment-contract` |
| 配備先を持つ artifact だけから source と destination の observation を導き、欠落、変更、古い entry を拒否する | `artifact-runtime-observation-contract` |
| profileの固定client roster、提供集合、型metadata、capability、installer、managed fileが固定fixtureに一致し、不正なbranch field、必須field欠落、freeform field、mode矛盾を変異入力で拒否する | `agent-client-roster` |
| 共通rulesが配備対象のSkillとsubagentをrouteし、`routing.nix`のSkill、agent、handoff、MCP providerが完全かつ重複せず、Skill本文とagent定義に各edgeがあり、raw toolは直接利用集合だけで、Claude CodeとOMPのrequired Skill preload、OpenCodeのSkill tool、Codexのdynamic定義が実配備sourceへ投影される | `agent-definition-rendering` |
| agent の最終 managed file から system、home、seed、artifact の配備を導き、gateway 一件、agentmemory client source、OMP の認証状態が管理外であること、旧 path と runtime identity の不在、既存物を壊さない seed を検査する | `agent-artifact-contract` |
| seed migration は宣言した command へ既存 config と home を argv で渡し、client 固有の分岐を共通 module に置かない | `agent-config-migration` |
| 生成 config artifact が配備先の source と一致する | `agent-artifact-contract`、`gateway-artifact-contract` |
| gateway が全 target へ HTTP で接続し、front の起動依存と子 process を持たない | `gateway-front-contract` |
| front が宣言した port で loopback に listen し、書き込み領域、backend dependency、通信方針を持つ | `mcp-front-contract` |
| browser target だけが session lifecycle を使い、inner listener、管理 listener、TTL grace、stdio executable が session front config に一致する | `mcp-front-session-lifecycle` |
| session front が session ごとに stdio state を分離し、個別 DELETE と TTL で子 process を終了して次の session を受け入れる | `mcp-session-front-behavior` |
| Playwright の front が生成物を runtime directory に閉じる | `playwright-front` |
| browser-runtime CapabilityがChromium packageを一度だけ公開し、PlaywrightとChrome DevToolsが同じcontractを使う | `browser-runtime-chromium-contract`、`chrome-devtools-front` |
| gateway が wildcard へ bind するので通信を cgroup で loopback に限る | `gateway-artifact-contract` |
| agentmemory backend の image、設定、mount、環境 file、health、upstream package が固定値と一致する | `agentmemory-container` |
| AgentMemory の lifecycle hook roster、endpoint、OpenCode plugin と upstream version が一致する | `agentmemory-client-integration` |
| agentmemory MCP front の package、port、backend unit が一致し、initialize に応答する | `agentmemory-front` |
| Crawl4AI backend の image、publish、credential option の型、read-only 属性、値、environment file、health contract が固定値と一致する | `crawl4ai-container` |
| Crawl4AI MCP front は SOPS の poison stub と canary A / B を用いた隔離評価で package spec と target projection を比較し、実 front artifact の環境変数と initialize probe の応答を検査する | `crawl4ai-front` |
| SearXNG backend の image、publish、standalone secret、settings template、health contract が固定値と一致する | `searxng-container` |
| SearXNG MCP front の package、port、backend unit が一致し、initialize に応答する | `searxng-front` |
| 生成 config artifact が構文として妥当である | `config-syntax` |
| SOPS secret 宣言から path、owner、group、mode の observation だけを導き、内容と source path を含めない | `sops-runtime-observation-contract` |
| 有効なcontainer applicationとservice contractのkeyが一致する | `container-application-registry` |
| OCI imageの宣言がcontainerとpull方針に一致する | `oci-image-contract` |
| container applicationのendpoint URLとportがOCI publish、unitがsystemd serviceに完全一致し、healthが宣言済みHTTP endpointを参照する | `nixos-toplevel`（`platform/containers/module.nix`のassertion） |
| Capability、MCP target、container backend、GitHub account、front集合が型付きassertionを満たす | `nixos-toplevel`（`capabilities/module.nix`と`platform/mcp/module.nix`のassertion） |
| image IDがcontainerを一意に指す | `nixos-toplevel`（`platform/containers/module.nix`のassertion） |
| 全 module から system closure を評価できる | `nixos-toplevel` |
| gateway port を変え、同じ固定 provider roster を使う第二の評価からも system closure を評価できる | `nixos-variant-toplevel` |

## runtime の振る舞い

| 制約 | 検証 |
|---|---|
| MCP session が active な GET body の間 reap されず、session front の listener address を loopback に固定できる | `agentgateway-session-lifecycle` |
| agent runtime の package、timer、四つの managed root、client roster と release tree observation が一つの contract から導かれ、wrapper が upstream binary、session metadata、共有 Cargo/XDG cache、共通 project build cache、明示済み環境値、元の終了 status を保つ | `agent-runtime-contract`、`agent-runtime-behavior` |
| agent 内の Nix build が明示 out-link を尊重し、既定では result symlink を作らない | `agent-nix-build-shims` |
| GitHub release installer は API digest、archive の member、論理 size、package-tree の required path を公開前に検査し、隔離環境で probe した single-binary または package-tree を固定 directory descriptor から公開する。相対 link、release 2 世代保持、rollback、並行更新、別 filesystem の visible path も fixture で検査する | `agent-installer-behavior` |
| agent cache GC が allocated bytes を正本にし、不正な managed path を検出すると削除前に失敗し、inactive project cache を先に回収して active session がない場合だけ共有 cache を空にし、再計測する | `agent-project-cache-gc` |
| source、command、環境が完全一致した成功だけを再利用し、raw 環境値を保存しない | `agent-verification-cache` |
| agent resource command と reaper の package、state root、timer が宣言どおりである | `agent-resource-contract` |
| agent が作った worktree だけを登録し、clean、HEAD 不変、未使用の場合だけ隔離と再検査後に回収する | `agent-resource-behavior` |
| WSL 再起動の要否を判定できる | `wsl-restart-policy` |
| cleanup が現在と保持中の Home Manager generation から backup の exact path を導き、home と system の削除を別の権限境界で実行する | `cleanup-home-backups` |
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
| tracked flake sourceのrootが固定した責務rosterと基盤fileだけを持ち、Agent、Skill、Capability、Platform、secret、identity、health、artifactのownerが分離され、CapabilityからAgentまたはSkillへの逆依存と旧責務pathが存在しない | `structure-responsibility-roots` |
| unit直下が許可したlayer file、material directory、子unitだけであり、移動済み資材が旧pathへ再作成されない | `structure-layer-names` |

## 形式

| 制約 | 検証 |
|---|---|
| Nix の整形 | `nixfmt` |
| Nix の未使用束縛 | `deadnix` |
| Nix の慣用 | `statix` |
| commit 件名が scope なし、50 文字以内の日本語一行である | `git-commit-message-contract` |
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
- optionを介した依存の意味が設計した責務に一致すること。物理importと禁止した逆依存は検査するが、公開contractを使う理由までは静的に判定しない。
