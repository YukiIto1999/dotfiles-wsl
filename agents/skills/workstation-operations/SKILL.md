---
name: workstation-operations
description: Locates where this NixOS-WSL workstation's declaration, deployed generation, and live state diverge, and changes the host only with explicit authorization. Use for failing dotfiles-doctor checks, failed systemd units or timers, unexpected packages or closure growth, why a store path is present, which package provides a file, Nix build logs, memory pressure, WSL VM or .wslconfig mismatches, and planning a rebuild, rollback, or agent-client update. Not for starting a project's dev environment, running project verification, or editing standards.
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
| WSL の VM と Windows | Windows の `%UserProfile%\.wslconfig`、稼働中の VM の値（`free -h`、`nproc --all`、`swapon --show`） |

`.wslconfig` の宣言、Windows 上の file、稼働中の VM の値は別の source であり、template の一致を VM への反映済みとみなさない。
`wsl.conf` と systemd の unit は Linux 側の宣言で、`.wslconfig` は WSL2 の VM 全体に作用する Windows 側の設定である。

project の起動や依存の問題は `local-development`、project の検査は `change-verification` が担う。
host 側の原因が見つかった場合だけ、ここで続ける。

## 読み取り専用で観測する

- 全体: `dotfiles-doctor`。各 check は失敗のときに次の操作を示す。
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

- 資源: `/proc/pressure/memory`、`systemd-cgtop -m`、`systemctl --user status agents.slice`、`journalctl -u systemd-oomd`。
  agent の session は `agents.slice` の下の scope で動き、memory の上限を超えた scope は systemd-oomd か kernel の OOM が止める。
- Windows 側の設定の期待値は `dotfiles-wsl-config` が表示する。
- OMP と定期 job: `systemctl --user list-timers 'dotfiles-*'`、`systemctl --user status dotfiles-omp-update.service`、`nix profile history --profile ~/.local/state/nix/profiles/omp`。

`memory-pressure` や `io-pressure` が高い間は、正常な service の probe も期限を超えるため、資源の観測を先に読む。

## 原因の owner を決める

食い違いの層と owner module を、checkout の `docs/design.md`（何をどこが持つか）と `docs/operations.md` から特定する。
宣言の誤りは owner module の source を直す変更として扱い、`change-verification` で検査し、`commit-writing` で commit してから適用へ進む。
稼働状態だけの問題（失敗した unit、古い世代で動く process）は、宣言を変えずに次の管理された入口で収束させる。

## 許可を得て変更する

次の操作は、対象、影響、戻し方を示して利用者の明示の許可を得てから行う。
許可された範囲を超える操作へ広げない。

| 変更 | 入口 | 許可の前に示すこと |
|---|---|---|
| 新しい世代の適用 | `dotfiles-rebuild build` で package の差を得て、許可後に `dotfiles-rebuild switch`（または次の WSL 起動で切り替える `dotfiles-rebuild boot`） | activation で止まる、再起動する service と影響を受ける作業 |
| 前の世代へ戻す | 許可後に `dotfiles-rebuild rollback` | 戻るのは system の世代だけで、client の profile、data、Windows の設定は戻らないこと |
| OMP の更新と戻し | `systemctl --user start dotfiles-omp-update.service`、`nix profile rollback --profile ~/.local/state/nix/profiles/omp` | 動いている session は起動時の版のまま動くこと |
| Windows 側 | `.wslconfig` の編集、WSL の停止 | 利用者が PowerShell や Windows の設定で行う操作として示す |

`dotfiles-rebuild` は既定で commit 済みの HEAD を build する。`build` は checkout と配備済みの世代を変えないため、許可の判断材料を作るために実行してよい。

次は許可があっても行わない。
PATH の `nixos-rebuild` の直接実行、`wsl --shutdown` と `wsl.exe --terminate` の自動実行、sysctl の引下げ、`drop_caches`、swap の取り外し、稼働中の受入や session や PTY の停止、Relay process の一括の kill、`nix-collect-garbage -d` による rollback 用の世代の削除。
WSL の再起動が必要な場合は、全 session の作業が終わってから利用者が PowerShell で実行する command を示す。

## 確かめて返す

適用や同期の後は、`dotfiles-doctor` と、問題が起きた実際の利用経路で収束を確かめる。
返却には、食い違った層、観測した command と終了値と出力の抜粋、owner と直す場所、実行した変更と許可の範囲、未観測の項目を分けて書く。
command の終了 0 だけで、service の稼働、Windows 側の反映、利用経路の回復を報告しない。
