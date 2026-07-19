# 0009. rebuild を immutable candidate の回復可能な apply に分ける

## 状態

Accepted

## 背景

従来の `dotfiles-rebuild` は root で flake の評価と build を行い、すべての変更を boot generation に
登録していた。一般ユーザーが確認した source と root が評価する source の同一性を保証できず、通常の
service や Home Manager の変更にも WSL 全体の再起動が必要だった。

`nixos-rebuild --store-path` は build 済み NixOS system を受け取り、設定の評価と build を省略できる。
ただし既定の re-exec は `config.system.build.nixos-rebuild` を再評価するため、`--no-reexec` も必要になる。
`--sudo` は system profile の更新と activation だけを昇格する。

## 決定

rebuild を snapshot、check、build、plan、receipt、apply、verify の pipeline にする。build までの純粋な
計算結果と、system profile、runtime、WSL を変える effect を receipt 境界で分ける。

1. untracked file を拒否する。
2. flake の `sourceSnapshot` を `nix build --out-link` で immutable な store path に固定する。build command
   自身が生成中から temporary GC root を持つ。
3. 同じ `path:` flake に対して `nix flake check` と candidate build を一般ユーザーで実行する。candidate の
   out-link は build command 自身に作らせる。
4. current、booted、system profile の store path を固定する。`nvd diff` は表示だけに使い、固定した
   current/booted と `dotfiles-wsl-restart-required --plan` から effect を決める。
5. source、candidate、開始時の system state、effect を persistent receipt に固定する。
6. flake が固定した `config.system.build.nixos-rebuild` の store path へ、candidate だけを
   `--store-path --no-reexec --sudo` 付きで渡す。
7. candidate closure 内の `dotfiles-doctor` で runtime convergence を検証する。

effect と適用方法を次の 4 種類に固定する。

| effect | 条件 | apply |
|---|---|---|
| `switch` | activation interface と `wsl.conf` が同じ | switch、WSL 停止なし |
| `switch-restart` | interface は同じで `wsl.conf` だけが違う | switch、WSL 停止 1 回 |
| `boot-restart` | interface だけが違う | boot、WSL 停止 1 回 |
| `boot-two-stage` | `user.default`、または interface と `wsl.conf` の両方が違う | boot、root 起動を挟む 2 段階 |

booted または current metadata が無い場合は `boot-two-stage` に倒す。candidate metadata の不備、
snapshot、check、build、diff、effect 判定の失敗は privileged apply より前に停止する。

`--plan` は apply と doctor を呼ばない。Nix store への snapshot と candidate build は実行するため、system profile と
runtime を変えない preview であり、完全に副作用がない処理ではない。

### receipt と回復対象

active receipt は configured worktree の `$GIT_COMMON_DIR/dotfiles-rebuild/active.json` に置く。
state root、`receipts`、`roots` の owner、mode、実 directory であることを全操作の前に検査する。receipt の
owner、mode、link count、schema、store path、effect/action、user、state、activation/verification の
組み合わせも読むたびに検証する。不正な receipt、引数、runtime state は終了 status 2 とする。

開始時の state は次の意味に分ける。

| field | 意味 |
|---|---|
| `previous.running` | `/run/current-system` が指す実行中 closure |
| `previous.booted` | `/run/booted-system` が指す boot closure |
| `previous.displacedProfile` | rebuild 前に system profile が指していた closure |
| `recoveryTarget` | `previous.running` と同じ自動 rollback 対象 |

system profile への登録だけでは、その closure が boot または live activation されたことを証明できない。
開始時に current と profile が違っていても拒否せず、`displacedProfile` は観測値として保存するが自動適用しない。
source、candidate、recovery target、booted、displaced profile は transaction 中だけ indirect GC root で保護する。
再開のたびに `nix-store --add-root ROOT --realise STORE_PATH` を冪等に実行し、user-facing symlink と
`/nix/var/nix/gcroots/auto` の registration が一対一であることを確認する。

receipt の作成、更新、archive と GC root の作成、削除は、file data と rename、link、unlink 後の親 directory を
`sync` する。GC root の作成では user-facing directory と Nix auto-root directory の両方を barrier に含める。
activation の結果と次の state は一回の atomic receipt 更新で確定する。activation 後に WSL を停止しても、
再開に必要な receipt と closure が先に永続化された状態にする。
途中の barrier が失敗した場合も実行可能な残りの barrier を試し、activation や WSL 停止手順へは進まない。

effect の計算後、persistent GC root の作成後、receipt の公開後、activation intent の公開前、intent の永続化後に、
current、booted、system profile を固定した runtime baseline と照合する。receipt schema v2 は activation attempt
ごとの baseline と、drift を検出した境界を持つ。`aborted` と `.abort != null` は同値とし、expected はその方向の
activation baseline と一致し、observed とは異ならなければならない。

中断後も観測した別 generation を新しい baseline と見なさない。`switch` が所有できる遷移は current/profile の
baseline から target までであり、booted は変えない。`boot` は再起動前には profile だけを target へ変え、
current/booted は変えない。三つすべてが target へ収束した状態だけは再起動済みとして扱う。一つでもこの遷移に
含まれない component があれば、他の component が target でも transaction 全体を中止する。
drift を検出した transaction は activation と自動 rollback を行わない。期待値と観測値を `aborted` receipt に残して
archive し、GC root を削除する。これにより、別の activation が置換した generation を古い recovery target で上書きしない。

### activation の単一入口

NixOS の `system.tools.nixos-rebuild.enable` を無効にし、同名の guard command を system path へ置く。
通常の system generation 更新は `dotfiles-rebuild` だけが行う。初回 bootstrap は生成済み command をまだ使えないため、
共通 operation lock の内側で、対象 flake の `config.system.build.nixos-rebuild` を build して store path から呼ぶ。
どちらも PATH 上の可変な `nixos-rebuild` は使わない。

この排他保証は対応する二つの入口に対するものである。root が system profile、古い generation の activator、
`switch-to-configuration`、別 flake の `nixos-rebuild` を直接実行する操作は境界外であり、receipt の回復保証を持たない。
上流実装は profile 更新と activation を別の処理として実行し、Nix の `nix-env --set` に expected-generation CAS はない。
そのため、対応入口を増やして比較だけを追加する設計は採らない。

### restart transaction

WSL 停止が必要な場合は activation 成功後も receipt を `restart-pending` に残し、終了 status 3 を返す。
表示する PowerShell command は receipt の distribution、candidate closure 内の helper、transaction ID に固定する。

再起動の観測値は次の object とする。

```json
{
  "kernelBootId": "113f961c-e5b9-4a55-9e48-ecfd0a16d1b7",
  "userspaceTimestampMonotonic": "53136349"
}
```

`kernelBootId` は `/proc/sys/kernel/random/boot_id`、userspace timestamp は system manager の
`UserspaceTimestampMonotonic` から取得する。文字列化した JSON 全体ではなく二つの field を比較する。
`boot-two-stage` は first boot が beforeApply と異なり、final boot が beforeApply と first boot の両方と
異なる場合だけ doctor へ進む。

`--resume` は receipt の candidate を再適用または再検証する。`--rollback` は recovery target をその時点の
current/booted state に対して再分類し、同じ effect state machine で適用する。rollback object は一度だけ作り、
`--rollback` の再実行で beforeApply と firstBoot を上書きしない。active な `complete` receipt が archive 前に
残った場合も、terminal marker を戻して rollback を開始できる。

activation 失敗は終了 status 4、doctor 失敗は 5 とし、どちらも active receipt と GC root を残す。成功時と
runtime drift の中止時は receipt を `$GIT_COMMON_DIR/dotfiles-rebuild/receipts/<transaction-id>.json` へ移し、
transaction の GC root を削除する。

SOPS enrollment の `generation-pending` 中に作る receipt は enrollment transaction ID を記録する。
resume と rollback は同じ marker が同じ phase にある場合だけ許可する。active rebuild がある間、SOPS の変更操作と
bootstrap は開始しない。

通常 rebuild は candidate、running generation、configured user の一致を要求する。`my.username` の変更は
home と repository path の移行を含むため、WSL の二段階 restart だけでは回復できない。`--plan` と apply の
両方で終了 status 2 とし、host identity migration の専用 transaction へ分離する。

## 影響

check と apply の間で checkout を再評価しないため、同じ candidate を検証して適用できる。root は Git、
flake、secret を評価せず、system profile と activation だけを変更する。`nvd` と
`nix-output-monitor` は表示専用で、effect 判定の入力にしない。receipt は mutable な運用 state だが、
candidate の build result や effect を再計算する入力にはしない。

初回 bootstrap は新しい command と boot metadata が存在しないため、flake が固定した上流実体の boot を使う。既存
host で新しい rebuild を current generation へ入れる前は、flake package の
`nix run .#dotfiles-rebuild` を使う。

## 一次資料

- [nixos-rebuild-ng: store path activation](https://github.com/NixOS/nixpkgs/blob/bd0ff2d3eac24699c3664d5966b9ef36f388e2ca/pkgs/by-name/ni/nixos-rebuild-ng/src/nixos_rebuild/services.py#L297-L335)
- [nixos-rebuild-ng: re-exec](https://github.com/NixOS/nixpkgs/blob/bd0ff2d3eac24699c3664d5966b9ef36f388e2ca/pkgs/by-name/ni/nixos-rebuild-ng/src/nixos_rebuild/services.py#L29-L84)
- [nixos-rebuild-ng: sudo boundary](https://github.com/NixOS/nixpkgs/blob/bd0ff2d3eac24699c3664d5966b9ef36f388e2ca/pkgs/by-name/ni/nixos-rebuild-ng/src/nixos_rebuild/nix.py#L634-L672)
- [nixos-rebuild-ng: profile 更新と activation の順序](https://github.com/NixOS/nixpkgs/blob/bd0ff2d3eac24699c3664d5966b9ef36f388e2ca/pkgs/by-name/ni/nixos-rebuild-ng/src/nixos_rebuild/services.py#L224-L240)
- [NixOS-WSL: Change the username](https://github.com/nix-community/NixOS-WSL/blob/add6b01c7ca72240046b5d541a74845423f1ee35/docs/src/how-to/change-username.md#L9-L20)
- [systemd v260: UserspaceTimestampMonotonic](https://github.com/systemd/systemd/blob/v260/man/org.freedesktop.systemd1.xml#L1777-L1793)
- [systemd v260: manager timestamp の serialize](https://github.com/systemd/systemd/blob/v260/src/core/manager-serialize.c#L121-L132)
- [Linux v6.18: boot_id](https://github.com/torvalds/linux/blob/v6.18/drivers/char/random.c#L1589-L1599)
- [Microsoft: WSL distribution の terminate](https://learn.microsoft.com/en-us/windows/wsl/basic-commands#terminate)
- [Nix 2.34: GC root](https://nix.dev/manual/nix/2.34/command-ref/nix-store/realise)
- [Nix 2.34.7: indirect root の登録順](https://github.com/NixOS/nix/blob/2.34.7/src/libstore/indirect-root-store.cc#L18-L42)
- [Nix 2.34.7: auto root の生成](https://github.com/NixOS/nix/blob/2.34.7/src/libstore/gc.cc#L41-L46)
- [Nix 2.34.7: `nix-env --set` の profile 更新](https://github.com/NixOS/nix/blob/2.34.7/src/nix/nix-env/nix-env.cc#L758-L801)
- [NixOS: installer tool の公開と `config.system.build.nixos-rebuild`](https://github.com/NixOS/nixpkgs/blob/bd0ff2d3eac24699c3664d5966b9ef36f388e2ca/nixos/modules/installer/tools/tools.nix#L279-L334)
- [GNU coreutils: sync](https://www.gnu.org/software/coreutils/manual/html_node/sync-invocation.html)
