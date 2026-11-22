---
name: workstation-operations
description: Locates where this NixOS-WSL workstation's declaration, deployed generation, and live state diverge, and changes the host only with explicit authorization. Use for failing dotfiles-doctor checks, failed systemd units or timers, unexpected packages or closure growth, why a store path is present, which package provides a file, Nix build logs, memory pressure or admission waits, OCI image pins, WSL VM or .wslconfig mismatches, and planning a rebuild, rollback, cleanup, image sync, or agent-client update. Not for starting a project's dev environment, running project verification, or editing standards.
---

# host の宣言と実状態の食い違いを切り分ける

workstation の問題を、宣言（checkout の source と評価結果）、配備した世代、稼働中の状態のどこで食い違ったかに分け、証拠と一緒に返す。
観測は読み取り専用で進め、適用、削除、再起動、Windows 側の変更は利用者の明示の許可を得てから、管理された入口で行う。

## 症状を層に分ける

| 層 | 正本と観測 |
|---|---|
| 宣言 | dotfiles-wsl の checkout。`nix eval --json .#nixosConfigurations.<host>.config.<option>` |
| 配備した世代 | `readlink -f /nix/var/nix/profiles/system`、`readlink -f /run/current-system`、`nix profile history --profile /nix/var/nix/profiles/system` |
| Linux の稼働状態 | systemd の system manager と user manager、journal、process、cgroup、`/proc/pressure/*` |
| WSL の VM と Windows | Windows の `%UserProfile%\.wslconfig`、稼働中の VM の値（`free -h`、`nproc --all`、`swapon --show`）、Windows の memory の snapshot |

`.wslconfig` の宣言、Windows 上の file、稼働中の VM の値は別の source であり、template の一致を VM への反映済みとみなさない。
`wsl.conf` と systemd の unit は Linux 側の宣言で、`.wslconfig` は WSL2 の VM 全体に作用する Windows 側の設定である。

project の起動や依存の問題は `local-development`、project の検査は `change-verification` が担う。
host 側の原因が見つかった場合だけ、ここで続ける。

## 読み取り専用で観測する

- 全体: `dotfiles-doctor --json`。
  失敗した check の ID から、その owner が `dotfiles.health.observations` に登録した宣言を `nix eval --json .#nixosConfigurations.<host>.config.dotfiles.health.observations --apply builtins.attrNames` で探す。
- unit: 宣言した manager に合わせて `systemctl --failed` と `journalctl -u UNIT -n 30`、または `systemctl --user --failed` と `journalctl --user -u UNIT -n 30`。
  同名の unit が別の manager にあっても、宣言していない manager の状態で代えない。
- package と closure:

| 問い | 入口 |
|---|---|
| 二つの世代の package の差 | `nvd diff /run/current-system CANDIDATE` |
| ある store path が含まれる理由 | `nix why-depends /run/current-system /nix/store/HASH-NAME` |
| 二つの derivation の差 | `nix-diff "$(nix-store -qd /run/current-system)" CANDIDATE.drv` |
| file を提供する package | `nix-locate -w /bin/NAME`。固定した索引のため、無結果を不存在とみなさない |
| 保存された build log | `nix log /nix/store/HASH-NAME.drv` |
| closure の大きさ | `nix path-info -Sh /run/current-system` |

- 資源と開始待ち: `dotfiles-observe-workload | jq '.outcomes, .resources'`、`dotfiles-windows-resource-collector status`、`journalctl -t dotfiles-supervise -o cat | jq -c .`。
  Windows の値は診断であり、検証の入場の判定には guest の値が使われる。
- container の image: `dotfiles-sync-images --status`（不足か pin 切れで exit 1）、`dotfiles-image-digest IMAGE`（registry の linux/amd64 manifest digest を読む）。
- WSL の再起動の要否: `dotfiles-wsl-restart-required --plan CANDIDATE` が `switch`、`switch-restart`、`boot-restart`、`boot-two-stage` を返す。
  Windows 側の設定の期待値は `dotfiles-wsl-config` が表示する。
- agent client と定期 job: `dotfiles-agent-supply status --json`、`systemctl --user status dotfiles-agent-journal.timer`。
- 削除候補: `dotfiles-cleanup` は `--delete` を付けなければ対象を表示するだけである。

doctor の `warn` のうち `observation did not finish within <秒数>s` は観測が期限内に終わらなかったことだけを示し、対象の故障とは扱わない。
`memory-pressure` や `io-pressure` が高い間は、正常な service の probe も期限を超えるため、資源の観測を先に読む。

## 原因の owner を決める

食い違いの層と owner module を、checkout の `docs/reference/change-map.md` と該当する `docs/operations/` の文書から特定する。
宣言の誤りは owner module の source を直す変更として扱い、`change-verification` で検査し、`commit-writing` で commit してから適用へ進む。
稼働状態だけの問題（失敗した unit、古い世代で動く process、pin の切れた image）は、宣言を変えずに次の管理された入口で収束させる。

## 許可を得て変更する

次の操作は、対象、影響、戻し方を示して利用者の明示の許可を得てから行う。
許可された範囲を超える操作へ広げない。

| 変更 | 入口 | 許可の前に示すこと |
|---|---|---|
| 新しい世代の適用 | `dotfiles-rebuild --plan` で候補 ID、package の差、再起動の分類を得て、許可後に `dotfiles-rebuild --candidate ID` | activation で止まる、再起動する service と影響を受ける作業 |
| 前の世代へ戻す | `dotfiles-rebuild --rollback --plan`、許可後に `dotfiles-rebuild --rollback` | 戻るのは system の世代だけで、client の profile、data、Windows の設定は戻らないこと |
| 削除 | `dotfiles-cleanup --delete`、system 側は root で `dotfiles-cleanup --system --delete` | 事前の表示で確かめた対象 |
| image の同期 | `dotfiles-sync-images` | 取得する image と digest |
| agent client の更新と戻し | `dotfiles-agent-supply update CLIENT`、`dotfiles-agent-supply rollback CLIENT` | 対象 client と、動いている session への影響 |
| Windows 側 | `.wslconfig` の編集、`dotfiles-windows-resource-collector install`、WSL の停止 | 利用者が PowerShell や Windows の設定で行う操作として示す |

`--plan` は隔離した source で検証と build を行い、checkout と配備済みの世代を変えないため、許可の判断材料を作るために実行してよい。
ただし T1 と system closure の build を伴う重い処理なので、commit 済みの source が揃ってから一度だけ実行する。
`dotfiles-rebuild` の終了 status は、2 が拒否か失敗で何も変えていない、3 が適用済みで WSL の boot 移行が未完了、4 が checkout の変化で未適用、5 が activation の途中の失敗で部分適用の可能性、を示す。
5 を復旧済みと報告せず、profile、running system、`systemctl --failed` を読み直す。

次は許可があっても行わない。
PATH の `nixos-rebuild` の直接実行、`wsl --shutdown` と `wsl.exe --terminate` の自動実行、sysctl の引下げ、`drop_caches`、swap の取り外し、稼働中の受入や session や PTY の停止、Relay process の一括の kill、`nix-collect-garbage -d` による rollback 用の世代の削除。
WSL の再起動が必要な場合は、全 session の作業が終わってから利用者が PowerShell で実行する command を示す。

## 確かめて返す

適用や同期の後は、`dotfiles-doctor` と、問題が起きた実際の利用経路で収束を確かめる。
返却には、食い違った層、観測した command と終了値と出力の抜粋、owner と直す場所、実行した変更と許可の範囲、未観測の項目を分けて書く。
command の終了 0 だけで、service の稼働、Windows 側の反映、利用経路の回復を報告しない。
