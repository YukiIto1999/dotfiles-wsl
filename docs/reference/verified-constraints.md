# 機械検証に固定した制約

**読み手:** どの制約が自動で守られ、どれが守られていないかを調べたい人。作業中に読む。

重要な制約は文書やレビューの指摘で運用せず、build で落ちる形に固定する。この表は固定済みの制約と、その検証手段を列挙する。監査はこの表を照合の対象にする。

`nix flake check` が全件を実行する。個別に走らせるときは `nix build .#checks.x86_64-linux.<検証>` を使う。

## 宣言と実状態

| 制約 | 検証 |
|---|---|
| PATH 上の実行ファイル名を二人以上が所有しない | `toolchain-single-owner` |
| 宣言した language server の command が package に存在する | `lsp-command-present` |
| 上流 release から作った binary が空環境で起動する | `toolchain-binary-runs` |
| LSP roster と各 CLI の登録が一致し、拡張子が衝突しない | `lsp-registration` |
| telemetry collector の config が妥当で receiver が loopback に閉じる | `telemetry-collector-config` |
| SonarQube の server と DB が同じ credential を見て DB port を公開しない | `sonarqube-topology` |
| 生成 config artifact が配備先の source と一致する | `config-artifact-contract`、`mcp-artifact-contract` |
| 生成 config artifact が構文として妥当である | `config-syntax` |
| doctor manifest が各 module の宣言と一致する | `doctor-manifest-contract` |
| OCI image の宣言が container と pull 方針に一致する | `oci-image-contract` |
| MCP target 名が互いに prefix 衝突しない | `nixos-toplevel` (`mcp/module.nix` の assertion) |
| image id が container を一意に指す | `nixos-toplevel` (`mcp/module.nix` の assertion) |
| 全 module から system closure を評価できる | `nixos-toplevel` |

## runtime の振る舞い

| 制約 | 検証 |
|---|---|
| MCP session が active な GET body の間 reap されない | `agentgateway-session-lifecycle` |
| doctor が manifest 契約と probe の失敗を正しく分類する | `doctor-runtime` |
| rebuild が効果を transaction として振り分ける | `rebuild-routing`、`rebuild-entrypoint`、`rebuild-attempt` |
| 公開が原子的で、中断後に再開できる | `atomic-publication`、`active-publication`、`preparation-parent-evidence` |
| gc root が観測できる | `gc-root-observer` |
| WSL 再起動の要否を判定できる | `wsl-restart-policy` |
| SOPS の鍵配置と権限境界が保たれる | `sops-policy`、`sops-verifier-runtime`、`privilege-boundary` |
| agentmemory の credential が環境ファイル経由で渡る | `agentmemory-env` |
| Playwright の出力先が session ごとに閉じる | `playwright-runtime` |

## 文書

| 制約 | 検証 |
|---|---|
| 文書間と source への参照が切れていない | `docs-links` |
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
| shell の静的検査 | `shellcheck` |
| GitHub Actions workflow の妥当性 | `actionlint` |
| 開発ツールの所有が system と home で重複しない | `development-tool-ownership` |

## 固定できていない制約

次は現在レビューでしか検出できない。検証手段を足すまで、この節に残す。この節には check 名を書かないため、`docs-constraint-coverage` の網羅検査は届かない。項目の古さは、検証手段を足すときに手で確かめる。

- 文書の種別が混ざっていないこと。読み手の明示は検査するが、内容が手順と説明を混ぜていないことは検査していない。
- 参照文書が宣言の値を転記していないこと。roster や件数の転記は検査していない。
- 一つの責務の宣言、実装、test が同じ場所にあること。配置の規約を検査していない。
