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

operation lock は Git common directory の inode と従来の `dotfiles-operation.lock` の inode をこの順で lock する。前者を新しい
authority、後者を旧 generation との互換 bridge とし、移行中は両方を保持する。canonical lock file は temporary file の data sync、
atomic no-replace、canonical file と親 directory の sync で初期化する。変更操作だけが未初期化 state と、旧 publisher が残した
同一 inode の hardlink residue を修復できる。status と plan は既存 lock だけを取得し、state を作成または回収しない。

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

### verifier failure の successor

activation 済み candidate の doctor 自体に欠陥がある場合、固定 candidate の `--resume` は同じ欠陥を再実行する。
親 receipt の candidate を差し替えると、source、candidate、activation journal の対応が壊れる。親を先に archive して
通常 rebuild を始めると、active receipt が存在しない区間と親子関係のない履歴が生じる。この二方式は採用しない。

review 済み checkout package の `--forward-recover` は、schema v3 または v4 の doctor verification failure を親とする
schema v4 successor transaction を作る。親は activation succeeded、末尾 attempt succeeded、`after-profile-commit`、
verification failed、`failureStage = "doctor"` でなければならない。SOPS enrollment、rollback、abort、cancellation がなく、
current と profile が親 candidate、cold-start state が `switch` であることも要求する。

新 candidate の snapshot、check、build、diff、effect、user を評価し、OCI manifest schema と candidate closure 内の
`dotfiles-rebuild`、`dotfiles-sync-images`、`dotfiles-doctor` を検査する。親 receipt の exact bytes は
`lineage/<parent-id>/verification-failed.json` へ保存する。prepared child は
`successor-preparations/<parent-id>-<child-id>.json`、write-once の live authorization は
`successors/<parent-id>.json` へ保存し、lineage artifact と合わせて mode `0400` とする。authorization は親 receipt の
SHA-256、子 receipt の path、byte 数、SHA-256、三つの helper、OCI manifest の store path と hash、activation baseline、
5 本の GC root を固定する。prepared child の parent metadata は、active、lineage、garbage に存在する全 parent evidence の
path、byte 数、SHA-256 と transaction state に一致させる。GC root は user-facing symlink と Nix auto-root registration を
一対一で検証する。

authorization は OCI の同期状態を持たない。active 親を維持したまま、固定した child manifest に対する既存
`dotfiles-sync-images` transaction だけを許可する。readiness は candidate helper の `--status` から導出する。未同期なら
authorization と子の persistent root を残して終了し、同期後の `--forward-recover` は checkout を再評価せず同じ child を
再利用する。live authorization が有効な間の forward / cancel は candidate closure に固定した rebuild helper へ `exec` し、operation lock を
取り直して authorization と runtime を再検証する。controller 選択より先に successor protocol 全体を読み取り専用で検証し、erasure が
存在する場合は authorization より優先して失効済みと判定する。同期と再試行の案内もこの固定 helper の絶対 path を使う。
authorization 公開中は親の resume、rollback、abort を拒否する。`--cancel-forward-recover` は親 receipt を変更せず、
`successor-erasures/<parent-id>-<child-id>.json` に失効権限を先に固定する。cleanup は lineage と子の persistent root を
`successor-garbage/<parent-id>-<child-id>/` へ移してから、列挙済みの file と directory だけを削除する。各 mutation の直前に
erasure を再検証し、停止後も認証済み subset から再開する。通常ユーザーは Nix daemon 所有の indirect auto-root directory を
変更しない。user-owned persistent root の削除で dangling になった registration は daemon と GC の管理へ戻す。
erasure 公開時点で live authorization は失効する。以後は review 済み checkout が write-once erasure の列挙した対象だけを
検証、削除する。cancel 完了時は erasure も retire し、親の recovery operation を再び許可する。

Nix の indirect root publisher が残し得る direct root の `<root>.tmp-<pid>-<random>` と daemon auto-root の
`<hash>.tmp-<pid>-<random>` も protocol state として扱う。一回の direct-root scan と一回の auto-root scan から、確定 direct、
temporary direct、確定 auto、temporary auto の四集合を作り、write-once erasure schema v2 に固定する。live authorization は
五組すべてが確定し temporary がない場合だけ公開する。取消しは認証済み user-owned root と temporary だけを削除し、daemon-owned
entry は確定、temporary、dangling のいずれも変更しない。

readiness が成立したら、親 receipt と runtime baseline を再検査し、prepared child を `active.json` へ atomic replace する。
停止時の active receipt は親または子のどちらかであり、間に idle state を作らない。authorization の公開前に停止した
partial state は次の effect command だけが回収し、`--status` と `--plan` は未完了と不正を区別して status 2 で停止し、修復しない。
lineage、preparation、authorization、handoff、erasure、archive の一時ファイルは state root 直下の
`.successor-<kind>-<parent-id>-<child-id>.<suffix>` に置く。active 親は自分が親である entry、active 子は自分と direct parent の
組に属する erasure と archive entry だけを回収できる。未知の entry や identity の不一致を発見した場合は、削除せず
protocol error として停止する。

`active.json` の初回作成は transaction ID を含む temporary からの atomic no-replace、receipt 更新と handoff は atomic replace と
する。旧 hardlink publisher の residue は canonical active と同一 inode であることを含む完全な identity が一致する場合だけ
effect command が回収する。読み取り専用操作は active publication residue を変更しない。

handoff 後は lineage artifact から親の `superseded` receipt を再構成する。親の activation と doctor failure は変更せず、
successor ID、source、candidate、作成時刻、artifact metadata だけを追加する。この metadata は active または archive にある
実 child と相互検証する。`superseded` は検証成功ではなく、回復責任を子へ移した終端 state である。子の recovery target、
`previous.running`、`previous.displacedProfile` は親 candidate とし、
`previous.booted` は handoff 時の実測値にする。親 archive の公開または root cleanup で停止しても、子の `--resume` が
同じ lineage から冪等に完了する。

schema v4 の子が doctor verification failure になった場合も、同じ protocol で次の successor を作る。中間世代の
`superseded` receipt は既存 lineage と新しい supersession を両方保持する。validator は ancestor artifact を transaction ID、
path、byte 数、SHA-256、candidate と recovery target の関係でたどる。scanner は preparation、authorization、erasure の
全 edge に parent ごとの child 一意性、child ごとの parent 一意性、非循環性を要求する。履歴は分岐のない直線 chain になる。
schema v4 の active child に対する resume、first-boot、rollback、abort は lineage が固定した child rebuild helper が実行する。
未認可の successor 準備は protocol を修復できる review 済み checkout controller、live authorization が有効な間の forward/cancel は
認可済み child helper が実行する。erasure 公開後の forward/cancel は、失効した authorization ではなく write-once erasure を
authority として review 済み checkout が処理する。

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
