# Rebuild

**読み手:** 設定を適用する運用者と、適用失敗から復旧する運用者が、作業中に読む。

通常の適用と前世代へのrollbackは`dotfiles-rebuild`を入口にする。
NixOSのgenerationは復旧対象を保持するが、switchの非ゼロ終了だけでは、profile、`/run/current-system`、各serviceの状態が一致しているか判断できない。

## 適用

checkoutの変更を確認してcommitし、planを確認してから適用する。

```sh
dotfiles-rebuild --plan
dotfiles-rebuild
```

tracked working treeに未commitの変更があれば、plan、通常の適用、rollbackのいずれも終了status 2で止まる。
stageしただけの変更も未commitであり、検査の失敗もcleanとして扱わない。
新しいsource fileはflakeから見えるように追跡し、変更をcommitする。
初回enrollmentだけは[セットアップ](getting-started.md#再起動とcommit)の順序でboot generationを用意し、再ログイン後に差分をcommitしてから通常のrebuildへ進む。

`--plan`はcandidateを用意し、現在のgenerationとの差分とWSL再起動の要否を表示するが、profileやserviceを切り替えない。
WSLのplanは`switch`、`switch-restart`、`boot-restart`、`boot-two-stage`のいずれかである。
適用は固定したupstreamの`nixos-rebuild switch`へ委譲し、再起動が必要ならWindows側のcommandを表示する。

inputやpackageを更新すると、MCP frontやcontainerを含むserviceがactivationで再起動することがある。
別のsessionが作業中なら、source更新と検査までを先に済ませ、service切替とWSL再起動はその作業が終わってから実行する。

## Inputの更新

NixOS、WSL、Home Managerのstable branchを維持したまま、checkoutのrootで更新する。

```sh
nix flake update nixpkgs nixos-wsl home-manager sops-nix
```

devenvとactrunは、`flake.nix`の公式release commitを差し替えた後に`nix flake lock`でupstreamの依存を固定する。
hostのnixpkgsには追従させず、host全体のchannelを変えずに各公式packageのcompilerと依存を使う。
devenvの公式packageはimport-from-derivationを使うため、version評価にもそのderivationの取得またはbuildが必要となる。

NixOS-WSLの更新で既定の`wsl.extraBin`に追加されたcommandは、project側の追加から外す。
`wsl-extra-bin-contract`で各`/bin`の名前の一意性と、必須commandの実行可能性を確認する。

## 失敗時の調査

buildまたはplanの失敗ではswitchを実行しない。
switchの失敗ではactivationが一部適用されている可能性があるため、前世代がactiveだと断定せず、profile、running system、serviceの状態を確認する。

```sh
readlink -f /nix/var/nix/profiles/system
readlink -f /run/current-system
nix profile history --profile /nix/var/nix/profiles/system
systemctl --failed
journalctl -b -p err
journalctl -u UNIT -n 30
```

調査した原因をsourceまたは対象service側で直し、source変更をcommitしてから再度`dotfiles-rebuild`を実行する。
変更したsourceをまだ適用せず、既存generationへ戻す場合は次のrollbackを使う。

## Rollback

通常の入口から、system profileのcurrent generationより前の、残っている直前のgenerationを選ぶ。
番号に欠番があっても、そのgenerationを選び、currentより新しいgenerationは選ばない。

```sh
dotfiles-rebuild --rollback --plan
dotfiles-rebuild --rollback
```

rollbackは新しいflakeをbuildせず、選んだgenerationのWSL metadataで再起動要否を判定する。
`--rollback --plan`は差分とplanだけを表示し、profileを切り替えない。
適用は固定したupstreamの`nixos-rebuild switch --rollback`へ委譲する。
前世代が残っていない場合、historyを読めない場合、metadataを判定できない場合はswitch前に終了status 2で止まる。
rollbackのswitchも失敗することがあるため、非ゼロなら同じ調査手順を使う。

rollbackはsourceのcommitを戻さず、CLIのlogin session、containerの永続data、Windowsの設定もrestoreしない。
復旧後はdoctorと実際の利用経路を確認し、次の通常rebuildで問題のsourceを再適用しないようにする。

## WSLの再起動

再起動が必要なら、対象hostの`dotfiles.workstation.wsl.distroName`を使うcommandが表示される。
これはLinuxのユーザー名やhost IDではなく、Windowsに登録したdistribution名である。
既定値では、他のsessionの作業が終わってからPowerShellで次を実行する。

```powershell
wsl.exe --terminate 'NixOS'
wsl.exe --distribution 'NixOS'
```

## 入口を保つ

PATHの`nixos-rebuild`は拒否するwrapperであり、直接のrollbackも受け付けない。
通常の適用とrollbackは`dotfiles-rebuild`を使い、dirty検査とWSL判定を迂回しない。
初回構築だけは`workstation/activation/rebuild/impl/bootstrap.sh`を使う。

profileやserviceを変えずに復旧候補を調べるsmokeでは、cleanなcheckoutで`dotfiles-rebuild --rollback --plan`を使う。
通常の`--plan`はcandidateのbuildを伴うが、いずれのplanもactivationとWSL停止を実行しない。
稼働中の実機で、smokeのために通常のswitchやrollbackを実行しない。
