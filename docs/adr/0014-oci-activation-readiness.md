# 0014. OCI image の同期を activation の明示的な前提条件にする

## 状態

Accepted

## 背景

ADR 0012 で registry 取得を `dotfiles-sync-images` に分け、ADR 0013 で receipt、Docker cache、稼働
container の収束検査を追加した。container unit が `pull = "missing"` のままでは、同期前の activation や
service restart が registry へ接続できる。明示同期が失敗しても Docker の暗黙 pull が補完するため、取得 effect の
入口も一つに定まらない。

`pull = "never"` へ切り替えるだけでは不十分である。未同期の candidate を apply すると、receipt を公開してから
container unit が失敗する。active rebuild を一律に同期拒否すると、固定 candidate を再開するための修復操作も
実行できない。

## 決定

`mkMcpBackend` が宣言する全 OCI container に `pull = "never"` を設定する。Nix 生成 image は従来どおり
`imageFile` を service 開始前に load する。upstream image を registry から取得する入口は
`dotfiles-sync-images` だけにする。

OCI image manifest を schema v2 に更新する。schema v1 は同期 command と doctor 用 inventory だけを表し、Phase 3 の
`pull = "missing"` 世代でも使われている。schema v2 は `pull = "never"` と active rebuild receipt に束縛した同期修復の
両方を持つ世代を表す。

rebuild は doctor manifest schema v4 と OCI image manifest schema v2 を持つ target に対し、target 内の
`sw/bin/dotfiles-sync-images --status` を operation lock の内側で実行する。forward の plan と apply では
candidate、effect、default user を表示した後、persistent GC root と receipt を作る前に検査する。
`prepared`、`apply-intent`、`activation-failed` から activation を再試行するときも、receipt に固定した candidate を
再検査する。verification だけを再試行する state は doctor に委ね、同じ検査を重ねない。

rollback は doctor manifest schema v4 と OCI image manifest schema v2 の recovery target だけを通常経路で開始する。rollback object の作成前に
同じ readiness 検査を行い、`rollback-intent` と `rollback-activation-failed` からの activation 再試行でも検査する。
schema v3 と v2 の doctor adapter は既存 transaction の verification 互換として残すが、新しい rollback の
activation には使わない。doctor schema v4 でも OCI manifest schema v1 の旧 generation は `pull = "missing"` を含み、
active receipt 中の同期修復にも対応しないためである。

readiness command の status 0 だけを activation 可能とする。status 1 は未同期または競合としてそのまま返し、target
内の同期 command を表示する。status 2 とその他の status、helper の欠落、非 executable は contract 不正として
status 2 にする。command の stdout と stderr は隠さない。新しい plan / apply の失敗時は receipt と persistent GC root を
作らない。active transaction の再開では target を GC から保護してから検査するため、receipt に記録済みの root を先に
冪等修復し得るが、receipt state、rollback object、activation は変更しない。

active rebuild 中の同期は一律には拒否しない。同期 command は共通 operation lock を取得した後、既存の full receipt
validator で active receipt を読む。command が埋め込んだ manifest の canonical path が、receipt の candidate または
recovery target にある `etc/dotfiles/oci-images.json` の canonical path と一致する場合だけ変更操作を許可する。
別 target と壊れた receipt は拒否する。`complete` receipt は archive 前の rollback を修復できるよう recovery target だけを
許可する。`rolled-back` と `aborted` は拒否する。active SOPS enrollment marker に加え、receipt の
`sopsEnrollmentTransactionId` が非 null の場合も拒否する。`--status` は読み取り専用なので
active receipt を検査しない。

新規ホストは bootstrap で boot generation を登録し、WSL を再起動して Docker を利用可能にする。その後、通常ユーザーで
`dotfiles-sync-images`、`dotfiles-rebuild`、`dotfiles-doctor` の順に実行する。初回 boot の upstream container unit は
image 未同期なら失敗し得るが、暗黙 pull へ戻さず、この continuation で収束させる。

## 影響

system activation と container restart は registry 取得を行わない。candidate の build、readiness、receipt、activation の
順が固定され、未同期は effect 境界の手前で止まる。中断後の修復も receipt が指定する target の manifest に束縛されるため、
checkout や別 generation の image state を誤って同期しない。

OCI image manifest schema v1 の generation と、doctor schema v3 / v2 generation への通常 rollback は終了 status 2 になる。
暗黙 pull を許す互換 override は設けない。
必要な旧設定は doctor schema v4 と OCI image manifest schema v2 を持つ generation へ再構築し、新しい generation として apply する。

実 Docker を使う外部 effect の検証では、明示同期済みの状態で `--pull never` の container restart が成功することを
別途確認する。flake contract は全 container の pull option と生成された unit script の `--pull never` を検査する。

## 一次資料

- [NixOS OCI container module: `pull` option](https://github.com/NixOS/nixpkgs/blob/bd0ff2d3eac24699c3664d5966b9ef36f388e2ca/nixos/modules/virtualisation/oci-containers.nix#L315-L327)
- [NixOS OCI container module: `imageFile` の load](https://github.com/NixOS/nixpkgs/blob/bd0ff2d3eac24699c3664d5966b9ef36f388e2ca/nixos/modules/virtualisation/oci-containers.nix#L395-L410)
- [NixOS OCI container module: Docker へ渡す `--pull`](https://github.com/NixOS/nixpkgs/blob/bd0ff2d3eac24699c3664d5966b9ef36f388e2ca/nixos/modules/virtualisation/oci-containers.nix#L488-L500)
- [Docker Docs: `docker image pull`](https://docs.docker.com/reference/cli/docker/image/pull/)
