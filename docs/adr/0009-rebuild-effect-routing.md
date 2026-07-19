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
5. candidate の OCI image manifest が schema v2 であることを確認し、candidate 内の
   `dotfiles-sync-images --status` で OCI image readiness を検査する。
6. source、candidate、開始時の system state、effect を persistent receipt に固定する。
7. flake が固定した `config.system.build.nixos-rebuild` の store path へ、candidate だけを
   `--store-path --no-reexec --sudo` 付きで渡す。
8. candidate closure 内の `dotfiles-doctor` で runtime convergence を検証する。

特権昇格の正本は NixOS が評価した `config.security.wrapperDir/sudo` とする。store 上の `pkgs.sudo` は setuid
wrapper ではないため、rebuild command の runtimeInputs に含めない。`nixos-rebuild-ng` は昇格 command を
`sudo` という実行名で組み立て、絶対パスを受け取らない。この上流 command を呼ぶ範囲だけ
`config.security.wrapperDir` を PATH の先頭へ置く。ほかの PATH を探索して権限境界を決めない。

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
receipt schema v3 は activation を一つの戻り値として直接書かない。attempt ごとに intent、runner start、結合した
stdout/stderr、outcome を append-only journal へ順に永続化し、receipt は各 artifact の path、byte 数、SHA-256 を
参照する。receipt は attempt の連番、ID、方向、runtime baseline、開始直前の boot instance、時刻、終了結果も投影し、
artifact の内容と照合する。
末尾以外の attempt は終端状態、aggregate result は末尾 attempt と一致しなければならない。directory は `0700`、
JSON は `0600`、確定 log は `0400` とし、owner と link count も再開前に照合する。
activation 後に WSL を停止しても、再開に必要な receipt、journal、closure が先に永続化された状態にする。
途中の barrier が失敗した場合も実行可能な残りの barrier を試し、activation や WSL 停止手順へは進まない。

effect の計算後、persistent GC root の作成後、receipt の公開後、activation intent の公開前、intent の永続化後に、
current、booted、system profile を固定した runtime baseline と照合する。receipt schema v3 は activation attempt
ごとの baseline と、drift を検出した境界を持つ。`aborted` と `.abort != null` は同値とし、expected はその方向の
activation baseline と一致し、observed とは異ならなければならない。

operation lock を新しい process が取得した後も receipt が `activating` なら、前の runner は終了済みである。partial
log だけが残った attempt は log を確定し、current、booted、profile と system profile generation から
`before-profile-commit`、`after-profile-commit`、`unknown` のいずれかへ分類して `indeterminate` に閉じる。
final log と outcome が両方あれば、transaction ID、attempt ID、終了コード、runtime snapshot を検証して receipt へ
再結合する。final log だけなら結果不明の attempt として閉じる。書き込み順に反する outcome 単独と、partial log と
final log の同居は拒否する。`chmod 0400` 後、rename 前の partial log は確定途中の状態として final 名へ進める。
durable outcome の runtime と boot instance が現在値、およびその attempt の baseline と一致し、action と
profile commit 境界に矛盾しない場合だけ再結合する。通常実行も outcome 公開前に同じ意味検査を通す。
target を指す runtime だけから、journal のない activation 成功を推定しない。

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

`--resume` は receipt の candidate を再適用または再検証する。activation を再試行する state では、target の OCI
image readiness を先に再検査する。`--rollback` は schema v4 の recovery target をその時点の current/booted
state に対して再分類し、同じ effect state machine で適用する。schema v3 / v2 target は暗黙 pull の可能性を排除できないため、
新しい rollback object を作らない。rollback object は一度だけ作り、
`--rollback` の再実行で beforeApply と firstBoot を上書きしない。active な `complete` receipt が archive 前に
残った場合も、terminal marker を戻して rollback を開始できる。

失敗時の回復案内は capability から生成する。固定 candidate の `--resume` は表示する。recovery target が doctor
schema v4 と OCI image manifest schema v2 を持つ場合だけ `--rollback` を表示する。profile commit 前で runtime、
boot instance、system profile generation が baseline のままと実測できる場合だけ `--abort` を表示する。
`--abort` は `cancelled` receipt を archive し、外部 runtime drift を表す `aborted` と区別する。schema v2 の既存
transaction は、配備時の source template、candidate helper、nixpkgs revision、上流 driver invocation が監査済み
allowlist と一致する場合だけ扱う。candidate helper は system closure 内の symlink であることと、その解決先が Nix store
配下の通常ファイルであることを確認してから内容を監査する。zero-effect を先に実測し、安全でなければ active schema v2
receipt を変更しない。
安全な場合は元 receipt を読み取り専用 artifact として保存し、schema v3 と `cancelled` を一度の active receipt 更新で
公開する。artifact 公開後に停止した場合は、owner、mode、link count と元 receipt の byte 列が一致するときだけ
冪等に再利用する。
schema v2 を作った current/candidate helper は `--abort` を持たないため、review 済み commit の checkout から
`nix run .#dotfiles-rebuild -- --abort <transaction-id>` を一度だけ実行する。この経路も同じ operation lock と
zero-effect 検査を通り、旧 candidate を activation しない。schema v3 以後は receipt 固定 helper を使う。

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
- [nixos-rebuild-ng: sudo command の構築](https://github.com/NixOS/nixpkgs/blob/bd0ff2d3eac24699c3664d5966b9ef36f388e2ca/pkgs/by-name/ni/nixos-rebuild-ng/src/nixos_rebuild/process.py#L153-L187)
- [nixos-rebuild-ng: profile 更新と activation の順序](https://github.com/NixOS/nixpkgs/blob/bd0ff2d3eac24699c3664d5966b9ef36f388e2ca/pkgs/by-name/ni/nixos-rebuild-ng/src/nixos_rebuild/services.py#L224-L240)
- [NixOS: security.wrapperDir と shell PATH](https://github.com/NixOS/nixpkgs/blob/bd0ff2d3eac24699c3664d5966b9ef36f388e2ca/nixos/modules/security/wrappers/default.nix#L236-L277)
- [NixOS: session PATH での wrapper 優先](https://github.com/NixOS/nixpkgs/blob/bd0ff2d3eac24699c3664d5966b9ef36f388e2ca/nixos/modules/config/system-environment.nix#L19-L29)
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
