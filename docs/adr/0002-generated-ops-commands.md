# 0002. 運用コマンドの設定生成

## 状態

Accepted

## 背景

`dotfiles-rebuild` / `dotfiles-doctor` / `dotfiles-cleanup` / `dotfiles-install-clis` は
`my.clis` と `my.mcp.targets` に依存する情報(CLI 一覧、gateway URL、target 名、
インストール手順)を必要とする。手書きスクリプトでこれらを二重管理すると、設定とスクリプトがずれる。

## 決定

`modules/commands.nix` が `config.my` から `modules/commands/{rebuild,doctor,cleanup,install-clis}`
の `@var@` を `builtins.replaceStrings` で埋め、`writeShellApplication` でビルドして
`environment.systemPackages` に載せる。`scripts/bootstrap.sh` は手書きのまま残す。
bootstrap は最初の system generation を登録する前に実行するため、config から生成されたコマンドをまだ参照できない。
対象 flake の `config.system.build.nixos-rebuild` だけを store path へ build し、共通 operation lock の内側から呼ぶ。

## 検討した代替案

`bootstrap.sh` も生成対象にする案。生成コマンドは system closure をビルドした後にしか存在せず、初回
bootstrap では参照できないため成立しない。不採用。

## 影響

`my.clis` や `my.mcp.targets` を変更すると、`dotfiles-doctor` 等の検査内容が追従する。
`writeShellApplication` は ShellCheck を build に含むため、ShellCheck 違反は nix build で検出される。
`bootstrap.sh` の `TARGET_USER="nixos"` は `my.username` の default と手動で同期を保つ必要がある。
