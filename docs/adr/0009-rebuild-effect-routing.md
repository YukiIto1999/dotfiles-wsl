# 0009. rebuild を immutable candidate の effect 別 apply に分ける

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

rebuild を snapshot、check、build、plan、apply、verify の一方向 pipeline にする。

1. untracked file を拒否する。
2. `nix flake archive` で作業ツリーを immutable な store path に固定する。
3. 同じ `path:` flake に対して `nix flake check` と candidate build を一般ユーザーで実行する。
4. `nvd diff` は表示だけに使い、`dotfiles-wsl-restart-required --plan` の effect で apply を決める。
5. `nixos-rebuild --store-path --no-reexec --sudo` へ candidate だけを渡す。
6. live switch だけは candidate closure 内の `dotfiles-doctor` で検証する。

effect と適用方法を次の 4 種類に固定する。

| effect | 条件 | apply |
|---|---|---|
| `switch` | activation interface と `wsl.conf` が同じ | switch、WSL 停止なし |
| `switch-restart` | interface は同じで `wsl.conf` だけが違う | switch、WSL 停止 1 回 |
| `boot-restart` | interface だけが違う | boot、WSL 停止 1 回 |
| `boot-two-stage` | `user.default`、または interface と `wsl.conf` の両方が違う | boot、root 起動を挟む 2 段階 |

booted または current metadata が無い場合は `boot-two-stage` に倒す。candidate metadata の不備、
archive、check、build、diff、effect 判定の失敗は privileged apply より前に停止する。

`--plan` は apply と doctor を呼ばない。Nix store への archive と build は実行するため、system profile と
runtime を変えない preview であり、完全に副作用がない処理ではない。

## 影響

check と apply の間で checkout を再評価しないため、同じ candidate を検証して適用できる。root は Git、
flake、secret を評価せず、system profile と activation だけを変更する。`nvd` と
`nix-output-monitor` は表示専用で、effect 判定の入力にしない。

初回 bootstrap は新しい command と boot metadata が存在しないため、従来どおり boot を使う。既存
host で新しい rebuild を current generation へ入れる前は、flake package の
`nix run .#dotfiles-rebuild` を使う。

## 一次資料

- [nixos-rebuild-ng: store path activation](https://github.com/NixOS/nixpkgs/blob/bd0ff2d3eac24699c3664d5966b9ef36f388e2ca/pkgs/by-name/ni/nixos-rebuild-ng/src/nixos_rebuild/services.py#L297-L335)
- [nixos-rebuild-ng: re-exec](https://github.com/NixOS/nixpkgs/blob/bd0ff2d3eac24699c3664d5966b9ef36f388e2ca/pkgs/by-name/ni/nixos-rebuild-ng/src/nixos_rebuild/services.py#L29-L84)
- [nixos-rebuild-ng: sudo boundary](https://github.com/NixOS/nixpkgs/blob/bd0ff2d3eac24699c3664d5966b9ef36f388e2ca/pkgs/by-name/ni/nixos-rebuild-ng/src/nixos_rebuild/nix.py#L634-L672)
- [NixOS-WSL: Change the username](https://github.com/nix-community/NixOS-WSL/blob/add6b01c7ca72240046b5d541a74845423f1ee35/docs/src/how-to/change-username.md#L9-L20)
