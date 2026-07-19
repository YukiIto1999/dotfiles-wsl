# 0008. WSL の再起動要否を cold-start manifest で判定する

## 状態

Accepted

## 背景

従来の `dotfiles-rebuild` はすべての変更を boot generation に登録し、変更内容に関係なく
`wsl -t NixOS` を案内していた。これでは systemd service や Home Manager の変更にも WSL 全体の停止が
必要になる。反対に、`/etc/wsl.conf` は WSL が distro 起動時に読むため、live activation だけでは
新しい値が反映されない。

再起動対象の option 名を手書きすると、NixOS-WSL の option 追加や default 変更に追従できない。
評価済み system closure には、その generation が生成した `etc/wsl.conf` がすでに含まれている。
NixOS-WSL は起動時に `/run/booted-system` を作り、live switch では既存の symlink を上書きしない。

`wsl.conf` が同じでも、candidate と current system の `init-interface-version` が異なる場合は
NixOS が live activation を拒否する。この場合も次の generation を起動するため WSL の停止が必要になる。

## 決定

WSL の cold-start manifest を system closure の `etc/wsl.conf` と定義する。candidate system と
`/run/booted-system` の manifest を byte 単位で比較する。さらに candidate と `/run/current-system` の
`init-interface-version` を比較する。どちらかに差がある場合だけ WSL の停止を必要とする。
booted manifest または current activation interface が読めない場合は、安全側に倒して再起動が必要と
判定する。candidate 側の metadata が読めない場合は build artifact の不備なのでエラーにする。

判定は `dotfiles-wsl-restart-required` に集約する。終了 status は、再起動が必要なら 0、不要なら 1、
入力不正なら 2 とする。`dotfiles-rebuild` はこの predicate を使い、manifest が同じ変更は
live activation だけで完了する。manifest が異なり `user.default` が同じ変更は、先に live activation で
`/etc/wsl.conf` を更新してから WSL を一度再起動する。

effect を返す `--plan` と、system closure から検証済みの default user を返す `--default-user` を分ける。
両方を同時には指定できない。rebuild は candidate と current generation の default user が構成済み user
と一致する場合だけ transaction を開始する。

activation interface だけが異なる場合は live activation を試さず、boot generation に登録して WSL を
一度再起動する。manifest と activation interface が同時に異なる場合は、boot 時の activation より前に
WSL が古い `wsl.conf` を読むため、default user 変更と同じ二段階の適用が必要になる。

`wsl.defaultUser` の変更は一般の cold-start 変更より制約が強い。NixOS-WSL の手順どおり
boot generation への登録、root で一度起動、再停止の二段階で適用し、live switch は使わない。この途中では
booted manifest と candidate が一致しても、WSL が新しい `user.default` をまだ読んでいないため、
predicate 単独で二段階目を省略しない。

このリポジトリでは `my.username` から `homeDir`、`dotfilesDir`、`wsl.defaultUser` を同時に導出する。
default user の変更は repository path と所有権も移す host identity migration であり、通常 rebuild の
rollback helper だけでは閉じない。classifier は `boot-two-stage` を返すが、通常 rebuild と `--plan` は
default user の不一致を終了 status 2 で拒否する。identity migration は別の transaction として設計する。

## 影響

classifier の入力として判定用 manifest や mutable marker は新設しない。NixOS がすでに生成した artifact
と boot generation を正本にするため、option 一覧の二重管理と初回 switch 時の誤記録がない。rebuild の
receipt は effect を決める入力ではなく、中断後も同じ判定結果と boot 観測を再開する運用 state である。
WSL を停止する条件は `wsl.wslConf` の明示値、NixOS-WSL が生成する default、NixOS activation interface
の変化に追従する。

## 一次資料

- [Microsoft: Advanced settings configuration in WSL](https://learn.microsoft.com/en-us/windows/wsl/wsl-config)
- [NixOS-WSL: Change the username](https://nix-community.github.io/NixOS-WSL/how-to/change-username.html)
- [NixOS-WSL: wsl-conf.nix](https://github.com/nix-community/NixOS-WSL/blob/add6b01c7ca72240046b5d541a74845423f1ee35/modules/wsl-conf.nix)
- [NixOS-WSL: native systemd activation](https://github.com/nix-community/NixOS-WSL/blob/add6b01c7ca72240046b5d541a74845423f1ee35/modules/systemd/native/default.nix#L32-L36)
- [NixOS: switch-to-configuration](https://github.com/NixOS/nixpkgs/blob/bd0ff2d3eac24699c3664d5966b9ef36f388e2ca/pkgs/by-name/sw/switch-to-configuration-ng/src/main.rs#L1851-L1870)
