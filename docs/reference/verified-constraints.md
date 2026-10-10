# 機械検証に固定した制約

**読み手:** どの制約が自動で守られ、どれが守られていないかを調べたい人。作業中に読む。

重要な制約は文書やレビューの指摘で運用せず、build で落ちる形に固定する。この表は固定済みの制約と、その検証手段を列挙する。監査はこの表を照合の対象にする。

全件は`nix run --no-write-lock-file .#verify-full`で実行し、個別には`nix build --no-link .#checks.x86_64-linux.<検証>`を使う。

## 宣言と実状態

| 制約 | 検証 |
|---|---|
| unit directory の各 segment が小文字 kebab-case である | `structure-unit-directory-names` |
| option の接頭辞が宣言した unit の名前と一致する | `option-namespace` |
| repository の Nix source に旧 option namespace と global helper injection が残らない | `dotfiles-option-namespace` |
| rebuildはunstaged/staged変更とGit検査失敗を拒否し、planで切り替えず、rollbackは残る直前generationをbuildせず選び、WSL判定とswitch失敗時の調査入口を示す | `rebuild-entrypoint` |
| doctor が owner の observation registry を欠落なく key 順に投影し、19 種類の observation kind を一つずつ汎用 probe に対応させ、旧 owner 固有 inventory と状態機械を持たない | `doctor-coverage` |
| 19 種類の observation kind の pass、warn、fail、resource、restart 集約と、数値集合の名前ごとの check を反映する。protocol の不正、過大出力、非ゼロ終了、期限前の kill は固定 message の fail に、期限切れは期限の秒数を示す warn にする。timer は `Result` が success でも service の最後の終了 status が非ゼロなら fail にする。slice の照合は実行 file の link 先の前方一致と cgroup の path の component の一致で行い、削除済みの実行 file を含め、名前が似た兄弟 directory と slice を区別する | `doctor-runtime` |
| Windows driveの観測inventoryは実mountから導き、hostのNix並列度とreserve、journal容量、swap、Windows committed memoryの値をruntime contractへ反映する | `machine-profile-contract` |
| WSL 専用 zram lifecycle、page cache回収timerの不在、journald、定期fstrimの無効化、Nix の容量 reserve、WSL の mount から実行時に見つけた Windows drive と committed memory の観測、root VHD の容量と `.wslconfig` の VHD 設定を宣言値と照合する観測、service非依存が宣言どおりである。WSL memory の観測が VMBus ring の確保失敗、親を失った Relay、boost を含む min と lowmem reserve を考慮した高次の空き block、PSI の閾値の境界を判定し、読めない入力を fail に、kernel log の走査の期限切れを warn にする | `host-stability-contract` |
| 宣言した time zone と default locale が実際の日時書式に現れ、UTC と C へ無言で戻らない | `host-locale-contract` |
| 登録簿が空にならない | `registries-non-empty` |
| runtime observation registry が 19 種類の observation kind、必須 field、path と ID、閾値、専用 command package を型で制限し、定義位置を owner と照合する | `observation-contract` |
| NixOS system factory が空・未知 ID の required roster と host 側の Nixpkgs config、overlays、package set、platform の上書きを拒否し、通常構成と variant の system closure を評価できる | `nixos-system-negative-eval` |
| 宣言、参照、暗号文の recipient が一致し、recovery 鍵が一つ、host 鍵が一つ以上あり、登録した全 host の鍵を含む | `sops-policy` |
| home に置く secret が user 所有の 0600 である | `sops-secret-file-mode` |
| loopback port を二人以上が bind しない | `loopback-port-single-owner` |
| container の argv が語彙・所有・loopback・cgroup 配置の contract に収まる | `container-argv-contract` |
| container を起こすのは ExecStart だけ | `container-exec-content` |
| container backend helper が init process、network 依存、cgroup 配置、再起動方針、publish 順序、依存、mount、環境 file、image 取得方針を一つの形で生成する | `container-backend-contract` |
| container service contract から service、restart、image、health、roster、配置、Docker build artifact GC の observation を漏れなく導き、追加と削除に追随する | `container-runtime-observation-contract` |
| 停止済みの testcontainers の回収が prune より先に走り、dangling image と BuildKit cache の回収順序、daemon policy、timer が固定され、Docker と backend が GC に依存しない | `docker-build-artifact-gc-contract` |
| 宣言済み backend が system.slice、それ以外の container が daemon の既定の上限付き slice に置かれ、既定の欠落、slice の上限の欠落、backend の flag の欠落、上限付き slice の下への入れ子を拒否し、生成した daemon config を dockerd が受理する | `container-cgroup-placement` |
| 停止済みの testcontainers の回収が label、状態、作成からの経過時間で対象を選び、running、若い container、他の label を残し、匿名 volume ごと削除し、一覧の失敗を空として扱わない | `docker-stopped-testcontainers-reclaim-behavior` |
| container の配置の観測が running の container ごとの scope の slice を宣言と照合し、宣言済み backend と宣言外の container の取り違えを fail にし、消えた scope を無視し、docker の失敗を observation の失敗にする | `container-placement-observation-behavior` |
| 共通container helperの参照が同一fileの別名経由も含めて承認済みCapability実装に限られ、CapabilityからAgentまたはSkillへの逆依存がない | `unit-boundary-name-only` |
| MCP targetのprovider集合がCapability registryから導かれ、通常評価とvariant評価で一致する | `mcp-provider-registry` |
| targetのprovider、server transport、server lifecycle、port、probe、通信方針、backend unitが固定fixtureに一致する | `mcp-target-contract` |
| provider 欠落と追加、ID と port の衝突、probe と通信方針の drift、front dependency と sandbox の欠落を変異入力で拒否する | `mcp-contract-mutations` |
| GitHub account と `github-<account>` target が完全一致し、欠落、追加、改名を拒否する | `github-account-target-contract` |
| repository-owned global module argument がなく、mutation fixture の定義元を unit の最長 path prefix で解決する | `mcp-source-boundary` |
| MCP gateway observer が initialize、session ID、tools/list、target ごとの tools/call を有界に実行し、要求の期限切れを期限の秒数を示す warn に、tools/call の MCP error、契約外の応答、接続の失敗を種類ごとの固定 message の fail にし、normalized envelope 以外の raw 出力を doctor へ渡さない | `mcp-gateway-observer` |
| MCP target、front、gateway から service、restart、roster、protocol observation を漏れなく導き、追加、削除、変更、stale entry に追随する | `mcp-runtime-observation-contract` |
| runtime identity fixture が現在の宣言から導いた MCP target port、gateway、container 名と network、secret 名、永続 path に完全一致する | `runtime-identity` |
| bootstrapの鍵生成、age/SOPS復号、誤鍵拒否、mode・owner・symlink拒否、宣言identity一致、enrollmentの手動commit後のclean化と同期から検証までの順序を隔離fixtureで観測する | `bootstrap-age-key` |
| 宣言した systemd service が listener か portless として登録される | `service-listener-registry` |
| stdio service lifecycle front の wrapper が自分の bind を決めない | `mcp-front-wrapper-bind` |
| service lifecycle front と native Streamable HTTP front の wrapper が条件付き exec で起動不能にならない | `mcp-front-starts` |
| Zvec-Grep front が native Streamable HTTP endpoint を直接公開し、agent toolset が意味検索だけを公開し、boot 時だけ前 boot の instance lock を除去する。front と direct mode の CLI は hash 固定の embedding model を network なしで読む | `zvec-grep-front` |
| PATH 上の実行ファイル名を二人以上が所有しない | `toolchain-single-owner` |
| 宣言した language server の command が package に存在する | `lsp-command-present` |
| Zvec-GrepのCLIが固定文字列の検索で一致した行を返す | `toolchain-binary-runs` |
| LSP roster と対応 client の登録が一致し、client ごとの server id 規則と OMP の有効条件を満たし、拡張子が衝突しない | `lsp-registration` |
| telemetry collector の config が妥当で receiver が loopback に閉じる | `telemetry-collector-config` |
| telemetry contract から collector service と restart count の observation を導き、service description を対象選択に使わない | `telemetry-runtime-observation-contract` |
| 生成 config artifact が登録簿に載り、宣言の変更に追随する | `artifact-registry` |
| GitHub account roster、primary、account ごとの owner の印が暗号化済み store の key 構造から導出され、別経路で読んだ store と一致し、暗号化 template、登録 artifact、Git identity の生成先が typed contract と一致する。fixture store で、primary という名前の owner を primary の印と読まないこと、primary への owner の印、大文字小文字だけが違う owner の重複、owner 名でない入れ子の key を拒否する | `account-deployment-contract` |
| fixture の owner の印から Home Manager が描画した Git 設定を git に読ませ、印のある owner の URL は担当 account の token file だけを helper に使い、印のない owner と名前が前方一致するだけの owner は gh の helper へ落ちる | `git-credential-routing` |
| 配備先を持つ artifact だけから source と destination の observation を導き、欠落、変更、古い entry を拒否する | `artifact-runtime-observation-contract` |
| profileの固定client roster、提供集合、型metadata、capability、installer、managed fileが固定fixtureに一致し、不正なbranch field、必須field欠落、freeform field、mode矛盾を変異入力で拒否する | `agent-client-roster` |
| OMP-only、Codexへの交換、Claude追加試用、Antigravity-onlyで非採用clientの配備、installer、health、policy、Skill rootを残さない | `agent-client-selection` |
| Claudeの共通policyをmanaged settingsのclaudeMdへ投影し、CLAUDE.mdの配備宣言を持たない | `agent-claude-managed-policy` |
| 生成した共通rulesが、Skill registryのlabelとid、subagentのfrontmatter、clientのmode宣言から独立に組んだ期待行と一致し、未置換markerを残さず、有効Capabilityで絞った`routing.nix`のSkill、subagent、handoffが完全かつ重複せず、各edgeを生成subagent sourceへ投影し、raw toolは直接利用集合だけで、Claude CodeとOMPのrequired Skill preload、OpenCodeのSkill tool、Codexのdynamic定義が実配備sourceへ投影される | `agent-subagent-rendering`、`agent-capability-gating` |
| agent の最終 managed file から system、home、seed、artifact の配備を導き、gateway 一件、project-memory client source、OMP の hook が symlink でない実 file として directory ごと配備されること、OMP の認証状態が管理外であること、旧 path と runtime identity の不在、既存物を壊さない seed を検査する | `agent-artifact-contract` |
| seed migration は宣言した command へ既存 config と home を argv で渡し、client 固有の分岐を共通 module に置かない | `agent-config-migration` |
| 生成 config artifact が配備先の source と一致する | `agent-artifact-contract`、`gateway-artifact-contract` |
| gateway が全 target へ HTTP で接続し、front の起動依存と子 process を持たない | `gateway-front-contract` |
| front が宣言した port で loopback に listen し、書き込み領域、backend dependency、通信方針を持つ | `mcp-front-contract` |
| session lifecycleを宣言するtargetのinner listener、管理listener、TTL grace、stdio executableがsession front configに一致する | `mcp-front-session-lifecycle` |
| session front が session ごとに stdio state を分離し、個別 DELETE と TTL で子 process を終了して次の session を受け入れる | `mcp-session-front-behavior` |
| browser-runtime CapabilityがChromium packageを一度だけ公開し、PlaywrightとChrome DevToolsが同じcontractを使う | `browser-runtime-chromium-contract`、`chrome-devtools-front` |
| heap解析が任意code実行toolと未load fileの比較を拒否し、実snapshotで保持object、session分離、unload後のhandle失効を確認し、同期regexのdeadline終了を他sessionへ波及させない | `heap-diagnostics` |
| gateway が wildcard へ bind するので通信を cgroup で loopback に限る | `gateway-artifact-contract` |
| Hindsight backendのAPI endpoint、named volume、read-only model mount、環境 fileの権限、health、stop timeoutが契約どおりである | `hindsight-container` |
| memory MCP frontのpackage、port、backend unit、health probeが一致する | `hindsight-front` |
| Crawl4AI backend の image、publish、credential option の型、read-only 属性、値、environment file、health contract が固定値と一致する | `crawl4ai-container` |
| Crawl4AI MCP front は SOPS の poison stub と canary A / B を用いた隔離評価で package spec と target projection を比較し、実 front artifact の環境変数と initialize probe の応答を検査する | `crawl4ai-front` |
| SearXNG backendのpublish、standalone secretとsettings templateの権限と値が契約どおりである | `searxng-container` |
| SearXNG MCP front の package、port、backend unit が一致し、initialize に応答する | `searxng-front` |
| 生成 config artifact が構文として妥当である | `config-syntax` |
| SOPS secret 宣言から path、owner、group、mode の observation だけを導き、内容と source path を含めない | `sops-runtime-observation-contract` |
| 有効なcontainer applicationとservice contractのkeyが一致する | `container-application-registry` |
| container Capabilityを一件だけ選んだ構成では対応するcontainer一式だけを配備し、container Capabilityを零件にした構成ではDocker、container Capability所有のMCP target、secret、artifactを配備しない | `container-capability-gating` |
| 非container Capabilityを選ばない構成では所有するMCP targetとsession variableを配備せず、provider集合と残存targetが一致する | `mcp-capability-gating` |
| `project-memory`を選ばない構成ではHindsightのhook package、記憶の収穫のcommandとtimer、client mode、managed file、および利用不能なSkill、subagent、handoff、policy記述を配備しない | `agent-capability-gating` |
| 有効なCapabilityまたはSkill依存を満たせないSkillをAgent clientへ配備しない | `skill-capability-gating` |
| OCI imageの宣言がcontainerとpull方針に一致する | `oci-image-contract` |
| container applicationのendpoint URLとportがOCI publish、unitがsystemd serviceに完全一致し、healthが宣言済みHTTP endpointを参照する | `nixos-toplevel`（`platform/containers/module.nix`のassertion） |
| Capability、MCP target、container backend、GitHub account、front集合が型付きassertionを満たす | `nixos-toplevel`（`capabilities/module.nix`と`platform/mcp/module.nix`のassertion） |
| image IDがcontainerを一意に指す | `nixos-toplevel`（`platform/containers/module.nix`のassertion） |
| 登録した各 host の全 module から system closure を評価できる | `nixos-toplevel`、`tcs-a295-toplevel` |
| gateway port を変え、同じ固定 provider roster を使う第二の評価からも system closure を評価できる | `nixos-variant-toplevel` |

## runtime の振る舞い

| 制約 | 検証 |
|---|---|
| MCP session が active な GET body の間 reap されず、session front の listener address を loopback に固定できる | `agentgateway-session-lifecycle` |
| agent runtime の package、timer、slice 配置、client roster と release tree observation が一つの contract から導かれ、wrapper が upstream binary、session metadata、共有 Cargo/XDG cache、checkout ごとの Cargo build-dir、明示済み環境値と project の出力先設定、元の終了 status を保つ | `agent-runtime-contract`、`agent-runtime-behavior` |
| launcher が upstream を memory 上限を宣言した user slice の session ごとの scope で起動し、argv を展開せず、upstream の終了 status と signal を返し、scope を作れなければ upstream を起動せずに失敗する | `agent-runtime-behavior` |
| launcher が Cargo の build-dir を全 session で共有する一つの root の下に `{workspace-path-hash}` で置き、その root が自分の directory でなければ client を起動せずに失敗する | `agent-runtime-behavior` |
| agent 内の Nix build が明示 out-link を尊重し、既定では result symlink を作らない | `agent-nix-build-shims` |
| project-memory runtimeが絶対cwd、Git common directory由来のproject scope、explicit scope、pending retainを契約どおり扱い、会話turnのhook eventをbackendへ送らずに拒否し、recall queryから注入blockを除き、明示的に保存した記憶だけを全頁から一覧する | `project-memory-runtime-behavior` |
| OpenCodeの同時sessionへ想起結果が混在せず、古いpromptの遅延応答が新しい結果を上書きせず、idleで想起結果を捨てて会話をmemoryへ送らない | `project-memory-client-integrations` |
| GitHub release installer は API digest、archive の member、論理 size、package-tree の required path を公開前に検査し、隔離環境で probe した single-binary または package-tree を固定 directory descriptor から公開する。raw asset は single-binary layout と path 成分のない entrypoint だけを受理し、mode 0700 で公開する。client ごとの失敗は隔離され、後続 client の公開を止めず、失敗した client 名だけを報告する。相対 link、release 2 世代保持、rollback、並行更新、別 filesystem の visible path も fixture で検査する | `agent-installer-behavior` |
| agent cache GC が allocated bytes を正本にし、不正な managed path を検出すると削除前に失敗し、持ち主の死んだ session と metadata のない session を回収し、launcher が死んでも scope が残る session を残し、内容が不正な metadata を持つ session は残して共有 cache を空にせずに失敗で終える。Cargo の build-dir は unit ごとに回収し、fingerprint と成果物のすべての file の atime と mtime から最終使用を測り、Cargo が build し直す unit でだけ読む JSON の atime は数えず、GC 自身は file を読まない。最終使用が直近 48 時間以内の unit、成果物、incremental の directory は回収せず、atime を更新しない mount では unit を回収せずに失敗で終える。最終使用が inactive の期限より古い unit と incremental の directory、48 時間使われていない fingerprint の無い成果物を先に回収し、合計が high watermark を超えれば全 entry の unit を最終使用の古い順に選び、lock を取れなかった entry を除いて選び直しながら、実際に回収した bytes で low watermark に達するまで回収する。成果物は名前の hash で fingerprint と照合し、hash を持たない成果物と lock file は残し、Cargo が `.cargo-build-lock` か `.cargo-lock` の flock を握る entry には触れない。Cargo の lock を取った後に、entry の中の file を実行している process があればその entry を見送り、entry を走査し直して、走査の後に最終使用か member の inode が変わった unit は回収しない。それでも上限を超え、active session がない場合だけ共有 cache を空にし、再計測する。48 時間の保護と lock で見送った unit による上限の超過は、session の有無を問わず記録して成功で終え、次の実行に回す。共有 cache を空にした後、それらの unit を除いても上限を超える場合だけ失敗で終える。計測と削除を lock の外で行い、lock の下では trash へ rename するだけなので、大きな cache の削除中も launcher は待たずに起動する。中断した実行が残した trash は次の実行が回収し、消せない entry を残した実行は失敗で終える。本物の Cargo が書いた build-dir でも、最後の fresh な build が使った unit は回収の後も fresh のままで、古い feature だけが使った unit は回収されて compile し直される | `agent-project-cache-gc` |
| source、command、環境が完全一致した成功だけを再利用し、raw環境値を保存しない。門はT1の`verify`を根で通した木だけを受理し、入口解決、cacheの保存と後始末、証跡公開までを予算に含める。証跡を検査前のsourceへ固定し、採取途中の編集と検査後の差し替えで未検査のsourceを受理しない。公開途中や動いているwrapperの証跡は受理せず、期限超過と中断では自分の走行だけを失効させる。PIDの再利用と前bootの完了済み証跡を失効させず、完了markerの部分書込は拒否する。後続の受理時に古い証跡を整理し、別の完了済み走行の証跡を失敗した走行が消さない。shellが木を変えた場合だけ門を立て、hookから呼ぶ入口の解決が失敗した場合も終了を拒否する | `agent-verification-cache` |
| Skillの読取記録は成功後の完全なcanonical本文に限り、本文の変更で失効する。`standard-conformance`の読取後は、実際のcoverage checkerが受理した同じ標準とprojectの監査receiptを要求し、未完了、異なる物理root、sourceや報告の変更で終了を拒否する。検査結果や証拠の内容の正しさは保証しない | `agent-skill-read-gate` |
| OMP hook が argv の容量制限を超える write と完全な read の event を実 gate process へ stdin で届け、本文の欠落、切り詰め、改ざん、更新後の再送を拒否する。20 秒の期限または中断では編集や終了を拒否し、出力 pipe を持つ子孫も停止する | `agent-omp-verification-gate-hook` |
| 検証の段の入口をNix app、devenv、package.json、Makefileの順に根の宣言から解決する。Nixで段を宣言した場合は他形式へ補完せず、評価失敗と未宣言を区別し、NixのGit sourceに含まれない未追跡fileを拒否する。根の下からの解決、段の区別、Git外の無応答も検査する | `verification-entry-resolution` |
| agent session 中の `git worktree add` が作った worktree だけを記録し、終了時に HEAD が作成時のままで変更と untracked file のないものだけを削除し、HEAD を進めたもの、変更を持つもの、session の外で作られたもの、同時の add で自分のものと区別できないものを残し、元の終了 status を保つ | `agent-runtime-behavior` |
| 作業日誌が区切り時刻から翌日の区切り時刻までの利用者の指示、応答、tool の意図、commit だけを model へ渡し、thinking、tool の結果、subagent の記録、範囲外の entry を渡さず、host ごとの file を push する。同じ日を作り直しても内容が同じなら commit を増やさず、timer は最後に完了した日までの未作成の日だけを選ぶ。model が失敗した日は file を作らずに後の日を記録して非ゼロで終わり、次の実行でその日を作る。一時 directory が Git の work tree の中にあれば model を呼ばない。機械名は宣言値で、宣言の無い host は host ID を使い、file 名に使えない機械名を型が拒否する | `agent-journal-behavior` |
| 記憶の収穫が前回成功した実行から後の利用者の発言だけを model へ渡し、応答、tool の結果、注入した記憶、subagent の記録を渡さない。将来の場面を返さなかった候補、保存済みの記憶と同じ内容の候補、source が保存済みの記憶にある発言を保存せず、場面を保存する本文に含めず、候補を session file と entry ID の source で保存する。pending は status が saved を返すまで保存済みと報告せず、資格情報に見える候補の拒否では失敗にしない。model や保存の失敗では非ゼロで終わり、読み終えた位置を進めない | `agent-memory-harvest-behavior` |
| WSL 再起動の要否を判定できる | `wsl-restart-policy` |
| 別PCのWSL資源、登録名、生成DNS、任意drive、Nix reserveと並列度を評価し、Windows準備用templateは表示だけを行う | `wsl-host-policy-contract` |
| wslviewはURL、Windows path、変換したLinux pathと特殊文字を単一targetとして扱い、不正引数、変換失敗、Windows終了statusを維持する | `wslview-behavior` |
| WSL の既定 user と root の systemd user manager を linger で常駐させ、WSL の自動終了後の起動でも login session を作れるようにする | `wsl-user-session-contract` |
| WSL の extraBin に必須の名前が揃い、名前が重複せず、store 由来の entry が実行可能である | `wsl-extra-bin-contract` |
| localとpluginの全SkillのSKILL.mdがfrontmatterを持ち、nameがregistry IDと一致し、descriptionが空でない | `skill-frontmatter-contract` |
| 外部Skill directoryを変換せず直接登録し、同IDの明示差替え、依存metadataの切替、client共有sourceへの反映を検査し、不正source、未知依存、曖昧な重複を拒否する | `skill-source-contract` |
| cleanup が現在と保持中の Home Manager generation から backup の exact path を導き、home と system の削除を別の権限境界で実行する | `cleanup-home-backups` |
| image sync が不足分だけを pull し、宣言済み image へ専用 namespace の tag を付けて dangling prune から外し、pin が切れた状態を status で検出する | `oci-image-sync-behavior` |
| HindsightのcredentialがSOPS templateからroot所有の環境 fileを経てcontainerへ渡る | `hindsight-container` |
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
| commit 件名が scope なし、50 文字以内の日本語一行であり、要約が読点と句点を含まず、動詞、形容詞、助詞で終わらない | `git-commit-message-contract` |
| pre-commit が日本語、空白、先頭の `-` を含む file 名でも staged の追加行を検査し、GitHub token を含む commit を拒む | `git-pre-commit-leak-contract` |
| 配備した global ignore が .NET、Rust、JS/TS、Python などの代表的な生成物と cache を除外し、検査対象の source、共有設定、lockfile は `git add` で追跡できる。repository の `.gitignore` の例外指定で共通除外を上書きできる | `git-hook-dispatch` |
| pre-commit が GitHub token、age 秘密鍵、既知の API token を含む実際の commit を本文を出力せずに拒む。secret の削除後は公開 age recipient と prefix 宣言を含む source の commit が成功する | `git-hook-dispatch` |
| 配備した hook を実際の git が起こし、dotfiles の検査が拒めば repository の `.githooks/` の hook を走らせず、通れば同じ argv と stdin(pre-push の ref の一覧を含む)で走らせ、その失敗の終了 status を返す。実行権の無い hook は黙って飛ばし、信頼していない repository の hook は走らせずに一行だけ伝える | `git-hook-dispatch` |
| pre-pushが宣言したT2を根で実行し、送信refのcommitとclean HEADの一致を要求する。差分、差分を隠すindexの印、検査中のsource変更、入口の解決失敗、検査の失敗を拒否し、remoteを更新しない。入口解決を含む予算超過では子孫を止める。宣言なしと削除だけのpushは検査を要求せず、入口未解決でも利用者の理由付き省略は記録を残す | `git-pre-push-verification` |
| nativeなT1を予算で止め、呼び出し元の期限や中断でも内側のprocess groupへ取消を届けて終了を待つ。取消を受けた検査が終了0を返しても成功扱いせず、親の終了後にTERMを無視する子孫の副作用を残さない | `verification-run-within` |
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
- commit 件名の要約が名詞で終わること。hook は動詞の終止形と過去形、「ない」「しい」「たい」、一部の助詞で終わる要約だけを拒否し、「設定を見直し」のような助詞に続く連用形、「遅い」のような形容詞、「のみ」「とか」で終わる要約は通す。「扱い」「の見直し」のような名詞と区別するには形態素解析が要る。
