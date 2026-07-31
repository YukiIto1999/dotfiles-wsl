# Doctor

**読み手:** 目的の作業をやり遂げたい運用者。作業中に読む。

`dotfiles-doctor` は current generation が宣言する期待値と実状態の収束を検査する。build 前の source 検査は `nix flake check`、apply 後の runtime 検査は doctor が担当する。

## 実行

人が調べるときは通常出力を使う。

```bash
dotfiles-doctor
```

機械処理や check ID の絞り込みには JSON を使う。

```bash
dotfiles-doctor --format json
```

`--format` に指定できる値は `human` と `json` だけである。JSON では stdout に document を1件だけ返す。

## 結果

| status | outcome | 判断 |
|---:|---|---|
| `0` | `healthy` | `pass` と `warn` だけ。実用状態に収束している |
| `1` | `degraded` | `fail` または依存元の失敗による `blocked` がある |
| `2` | `invalid` | manifest または検査結果の契約が壊れている |
| `2` | report なし | 引数が不正で、検査結果を生成する前に終了した |
| `130` / `143` | report なし | INT または TERM を受け、session の cleanup を試行した |

`warn` だけなら status 0 だが、警告の理由は確認する。`blocked` は検査対象を成功扱いした結果ではなく、依存元の失敗や競合のため probe を実行していない状態である。status 2 では runtime の個別修復より先に、manifest と current generation の整合性を調べる。

## Foundation

`foundation` は実行ユーザーと home、current generation、system profile、実行中 doctor、WSL の cold-start 状態を確認する。manifest の `error` は status 2 で終了する。それ以外の `fail` では、異なる generation や user の状態を混ぜないため、後続 phase が `blocked` になる。

まず `dotfiles-rebuild --status` を確認する。再起動待ちなら rebuild が表示した PowerShell command を完了し、active transaction なら同じ transaction を再開する。active transaction がなく current system と system profile が一致しない場合は、profile や symlink を直接直さず [Rebuild](rebuild.md)の通常経路で収束させる。

## Local

`local` は current generation が管理するファイル、AI CLI の固定 path、rules、skills、agent file、gateway 設定、WSL launcher、Nix の動的 loader を検査する。

失敗した path を home 配下で直接編集しない。対応する `modules/` または `share/` の source と current generation を確認し、必要な変更を rebuild する。AI CLI の実行ファイルがない場合は、通常ユーザーから配備し直す。

```bash
dotfiles-install-clis
dotfiles-doctor
```

## System

`system` は必須 systemd unit、OCI 同期 state と Docker image、SOPS host key の owner と mode を検査する。root probe は host key の内容を読まない。

unit の失敗は doctor が表示した unit を `systemctl status UNIT` で調べる。OCI の未同期や lock 競合は [OCI images](oci-images.md)の状態確認へ進む。SOPS metadata の失敗では鍵を表示、コピーせず、[SOPS enrollment](sops-enrollment.md)と[セキュリティ設計](../architecture/security.md)の配置条件を確認する。移行中に旧 home key が残る場合は警告、移行完了後は失敗になる。

## Active

`active` は稼働 container が期待する image を使っていること、AI CLI の version probe、Windows interop、MCP gateway の session lifecycle と各 target の tool 公開、gateway service の資源値を検査する。

`active.mcp.resources` は unit 検査と同じ `systemctl show` の結果から六つの値を読み、`MainPID` の `/proc/<pid>/fd` を数えて `fdCurrent` を出す。

| 値 | 意味 |
|---|---|
| `TasksCurrent` | gateway cgroup の task 数、session ごとに spawn される stdio front を含む |
| `fdCurrent` | MainPID が開いている file descriptor 数 |
| `MemoryCurrent` | cgroup 合計。process の RSS ではない |
| `MemorySwapCurrent` | cgroup の swap 使用量 |
| `LimitNOFILE` | systemd が課す hard 上限 |
| `LimitNOFILESoft` | soft 上限。`Too many open files` はこちらで起きる |

`LimitNOFILE` と `LimitNOFILESoft` だけが期待値を持ち、実値が manifest と違えば fail になる。tasks、FD、memory、swap には上限を置かず、値を取得できないことだけを fail にする。

container の検査が `blocked` なら、同じ image と unit の `system` 結果を先に直す。MCP の検査が `blocked` なら gateway の health unit、失敗なら initialize、pagination、session cleanup、該当 target の順に出力を読む。`active.mcp.resources` の失敗は property の欠落、非数値、FD 上限の不一致のいずれかで、message がどれかを示す。Windows interop の失敗では current generation の launcher と `cmd.exe` の起動経路を確認する。依存元を直した後に doctor を最初から再実行する。

## 制約

doctor は checkout の clean 状態、secret の値、AI CLI の配布元、内容、期待 version、login session、skill 本文、agent file の内容、agentmemory の保存内容を検査しない。source から system closure と設定を生成できるかは `nix flake check -L` で確認する。secret の復号は enrollment と bootstrap の担当である。

検査 inventory をこの文書へ手書きしない。期待値の正本は current generation の doctor manifest であり、各 module の宣言から生成される。

入口は [README](../../README.md)、初回検証の順序は[セットアップ](getting-started.md)、検査対象の構成は[構成概要](../architecture/overview.md)と [AI tooling](../architecture/ai-tooling.md)を参照する。
