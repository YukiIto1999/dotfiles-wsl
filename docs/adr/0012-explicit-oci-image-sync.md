# 0012. upstream OCI image の取得を明示的な同期操作に分ける

## 状態

Accepted

## 背景

MCP backend の upstream image は digest まで固定している。ただし image reference の固定だけでは、
Docker の local cache にその image が存在することを保証しない。NixOS の OCI container module は
`pull` の既定値を `missing` とし、Docker backend ではその値を `docker run --pull` へ渡す。
このままでは system activation と service 起動が network 取得を暗黙に伴う。

agentmemory image は upstream image と取得経路が異なる。Nix が `imageFile` を生成し、OCI container
module が service の開始前に `docker load` する。すべての image を一つの pull 処理へまとめると、
Nix で生成した artifact と外部 registry から取得する cache entry の責任が混ざる。

## 決定

`my.ociImages` を OCI image の typed inventory とする。各 entry は container 名、実行時の image
reference、取得責任を持つ。upstream entry は repository と sha256 digest を必須にし、Nix entry は
`imageFile` を必須にする。inventory が全 container 宣言を一度ずつ被覆し、image と `imageFile` の一致を
評価時に検証する。`/etc/dotfiles/oci-images.json` と同期 command は inventory から生成する。

`dotfiles-sync-images` は upstream entry だけを同期する。manifest に固定した digest reference を
Docker へ pull し、`docker image inspect` が返す `RepoDigests` に `repository@digest` が含まれることを
確認する。Nix entry は pull せず、OCI container module の `imageFile` 経路に残す。

同期 state は `~/.local/state/dotfiles-wsl/image-sync` に置く。変更操作は repository 共通 operation lock を
取得し、active な rebuild または SOPS enrollment があれば開始しない。その内側で image sync 専用 lock を
取得し、image ごとの receipt に manifest hash、image reference、digest、local image ID、成否を記録する。
receipt は同じ filesystem 上の temporary file を同期してから atomic rename し、親 directory も同期する。
一つの image が失敗しても残りの同期を続け、最後に失敗を集約する。古い image の削除は同期 command の
責任に含めない。

`--status` は state root が存在する場合、receipt と Docker cache を image sync 専用の shared lock 内で
照合する。state root が存在しない場合は未同期として status 1 を返し、directory や lock を作らない。
部分的または不正な state tree は修復せず status 2 とする。

最初の配備では OCI container の `pull = "missing"` を維持する。同期 command と検査側の schema を先に
配備できるようにし、rollback 可能な generation が揃った後で `pull = "never"` へ切り替える。暗黙 pull の
廃止は別の変更として検証する。

## 検討した代替案

すべての upstream image を Nix derivation に変換し、`imageFile` で load する案は採らない。Nix が生成する
agentmemory image には適するが、大きな upstream image を Docker cache と Nix store の両方に保持する。
外部 image は digest で内容を固定し、明示同期と receipt で取得 effect を管理する。

system activation の中で pull と digest 検証を行う案も採らない。activation 失敗と network failure が同じ
transaction に入り、中断後の取得結果を image ごとに診断できないためである。

## 影響

container の image 宣言と immutable manifest は同じ typed inventory から生成する。同期 command だけが
manifest を読み、mutable な Docker cache と receipt の照合で同期済みかどうかを判断する。Nix 評価時に
外部 registry へ問い合わせない。digest を更新するときは candidate の `dotfiles-sync-images` を実行してから
system generation を適用する。

この決定だけでは service 起動時の暗黙 pull は消えない。rebuild と doctor が未同期 image を扱う contract は
ADR 0013 で確定する。`pull = "never"` への移行は後続変更とする。

## 一次資料

- [NixOS OCI container module: `pull` option](https://github.com/NixOS/nixpkgs/blob/bd0ff2d3eac24699c3664d5966b9ef36f388e2ca/nixos/modules/virtualisation/oci-containers.nix#L315-L327)
- [NixOS OCI container module: `imageFile` の load](https://github.com/NixOS/nixpkgs/blob/bd0ff2d3eac24699c3664d5966b9ef36f388e2ca/nixos/modules/virtualisation/oci-containers.nix#L395-L410)
- [NixOS OCI container module: Docker へ渡す `--pull`](https://github.com/NixOS/nixpkgs/blob/bd0ff2d3eac24699c3664d5966b9ef36f388e2ca/nixos/modules/virtualisation/oci-containers.nix#L488-L500)
