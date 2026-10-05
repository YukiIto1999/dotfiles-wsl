# セットアップ

**読み手:** 新しいNixOS-WSLホストを構築する運用者が、作業中に読む。

初回構築は、Windows側の準備、host選択、host keyの登録、bootstrap、WSL再起動、enrollment差分のcommit、Agent CLIの導入、必要なOCI imageの同期、通常のrebuild、認証、検証の順に進める。
bootstrapはGit identityを含む初回boot generationを用意し、通常のrebuildはcommit済みのcheckoutだけを適用する。

## Windowsとcheckout

WSL distributionを用意する前に、[Windows側の準備](doctor.md)でRAM、CPU、DNS、VHD、driveの条件を確認する。
Windowsの`.wslconfig`はこのrepositoryから自動上書きされない。
既存のNix環境では、対象hostの`dotfiles.workstation.wsl.windowsConfigTemplate`を`nix eval --raw`で取得できる。
既存VHDの容量や保存場所は新しい設定だけでは変わらないため、既存distributionを移す場合も同じ手順のbackupとrestore条件を確認する。

初期distributionは[公式のNixOS-WSL導入手順](https://nix-community.github.io/NixOS-WSL/install.html#install-nixos-wsl)に従い、[公式release](https://github.com/nix-community/NixOS-WSL/releases)のx86_64用`nixos.wsl`から作成する。
このcheckoutはNixOS 26.05を使うため、同じ系列のstable imageを選び、公開されたSHA-256とdownloadしたfileのhashを照合する。
Windows PowerShellで既存の登録名を確認し、未使用の名前と新しい保存directoryを指定する。

```powershell
wsl.exe --version
wsl.exe --list --verbose
Get-FileHash -Algorithm SHA256 .\nixos.wsl
wsl.exe --import 'NixOS' 'D:\WSL\NixOS' .\nixos.wsl --version 2
wsl.exe --distribution 'NixOS' --user nixos
```

保存先は実際のdriveと空のdirectoryへ置き換える。
`NixOS`が登録済みなら別名を選び、既存distributionを削除せず、後続のhost profileにも同じ登録名を設定する。
WSL自体が未導入の場合は先に公式のprerequisiteを満たし、Windowsの再起動が必要なら既存sessionの終了を確認してから行う。

主ユーザーの既定値はNixOS-WSLの初期ユーザーと同じ`nixos`で、checkoutの既定値は`/home/nixos/environment/dotfiles-wsl`である。
このユーザーでログインし、Gitとflake CLIが未設定の初期imageでも使える一時的な作業環境を用意する。
clone前は公開repositoryの`flake.lock`からroot inputのnixpkgs固定revを取得し、そのGitを使う。

```bash
export NIX_CONFIG="${NIX_CONFIG:-}"$'\nexperimental-features = nix-command flakes'
NIXPKGS_REF=$(nix eval --impure --raw --expr '
  let
    lock = builtins.fromJSON (builtins.readFile (builtins.fetchurl
      "https://raw.githubusercontent.com/YukiIto1999/dotfiles-wsl/main/flake.lock"));
    source = lock.nodes.${lock.nodes.root.inputs.nixpkgs}.locked;
  in "github:${source.owner}/${source.repo}/${source.rev}"
')
nix shell "$NIXPKGS_REF#git" --command bash
```

開始したshellで以降の初回手順を続ける。
この準備はGitを恒久導入せず、初期imageのflake設定も書き換えない。

```bash
mkdir -p ~/environment
git clone https://github.com/YukiIto1999/dotfiles-wsl ~/environment/dotfiles-wsl
cd ~/environment/dotfiles-wsl
HOST_ID=tcs-a295
NIXPKGS_REF=$(nix eval --impure --raw --expr '
  let
    lock = builtins.fromJSON (builtins.readFile ./flake.lock);
    source = lock.nodes.${lock.nodes.root.inputs.nixpkgs}.locked;
  in "github:${source.owner}/${source.repo}/${source.rev}"
')
```

clone後はローカルの`flake.lock`から再取得した固定revを使い、公開branchが更新されてもbootstrapのGitをcheckoutのsourceに合わせる。

`HOST_ID`には`profiles/hosts/<host-id>.nix`が存在するIDを選ぶ。
hostの設定を変える場合は、信頼できる既存環境でprofileをcommitし、そのsourceを新しいホストへcloneする。
新しいhost IDは63文字以内の小文字英数字またはハイフンで構成し、英数字で始めて終える。

checkoutのrootで、構築対象の宣言を確かめる。

```bash
nix eval --raw ".#nixosConfigurations.${HOST_ID}.config.dotfiles.workstation.username"
nix eval --raw ".#nixosConfigurations.${HOST_ID}.config.dotfiles.workstation.dotfilesDir"
nix eval --raw ".#nixosConfigurations.${HOST_ID}.config.dotfiles.workstation.wsl.distroName"
git status --short
```

ユーザー名、checkoutの絶対path、Windowsのdistribution登録名は別の設定である。
`dotfiles.workstation.wsl.distroName`の既定値は`NixOS`で、Windowsの`wsl.exe --list --verbose`に表示される名前と合わせる。
ユーザー名やcheckoutを変更したhostでは、そのユーザーとsudo権限を初期環境で用意し、宣言どおりのpathへcloneする。
bootstrapはsudoの実行元ユーザーと実際のcheckoutが宣言に一致しなければ止まる。
host keyの登録を始める前のcheckoutには、未commitの変更と未追跡ファイルを残さない。

## Host key

[SOPSの鍵](sops-enrollment.md#新しいhostの登録)の手順で、このホスト専用の鍵を生成してrecipientへ追加する。
その手順はcheckoutの`age`と`sops`を取得し、`/var/lib/sops-nix`をroot:root、0700、`key.txt`をroot:root、0400として用意する。
rootだけが読めるhost keyでの復号はsudo経由で行い、成功するまでbootstrapへ進まない。
既存ホストの鍵をコピーせず、併用するrecipientを残す。

変更対象を確認する。

```bash
git diff --check
git diff -- secrets/sops/assets/.sops.yaml secrets/sops/assets/secrets.json
git status --short
```

変更は`secrets/sops/assets/.sops.yaml`と`secrets/sops/assets/secrets.json`の二つだけにする。
初回のGit identityはまだ配備されていないため、この時点ではcommitしない。
復号の確認後にrecovery keyの外部媒体を取り外し、暗号化済みの差分を保持したままbootstrapを実行する。

## Bootstrap

hostが宣言する主ユーザーからsudoを介し、root側でも固定revのGitを含むshellを用意して対象host IDを明示する。

```bash
sudo nix --extra-experimental-features 'nix-command flakes' \
  shell "$NIXPKGS_REF#git" --command \
  bash workstation/activation/rebuild/impl/bootstrap.sh --host "$HOST_ID"
```

sudoが設定する`SUDO_USER`をそのままbootstrapへ渡すため、rootへ直接ログインしたshellでは実行しない。
bootstrapはrootと主ユーザーのNix呼び出しにflake用のflagを明示し、upstreamのboot処理にも同じfeature設定を渡す。
初期imageのroot側にGitがない場合やflake CLIが無効な場合でも、通常ユーザーの一時shellのPATHだけには依存しない。

[bootstrap script](../../workstation/activation/rebuild/impl/bootstrap.sh)は、鍵の存在と権限、hostとcheckoutの一致、未追跡ファイルの不在、host keyによる復号を検査する。
続いてflakeが固定した`nixos-rebuild`で対象hostのboot generationを作り、`/etc/nixos`をcheckoutへのsymlinkにする。
初期imageではgeneric Linux向けnative CLIの実行に必要な`nix-ld`がまだ配備されていないため、bootstrap中にAgent installerを実行しない。
bootstrapは差分を自動commitせず、通常のrebuildのdirty拒否も変更しない。

## 再起動とcommit

bootstrapが表示するdistribution名を使い、PowerShellで対象のNixOS-WSLだけを停止して起動する。
他のsessionが作業中の場合は、その作業が終わるまで停止しない。
別名のdistributionもWSL2のkernelを共有するため、別名登録だけでは既存環境との資源やnetworkの分離を保証しない。
既存のdotfiles環境が稼働しているPCで並行検証する場合は、zramとcontainer networkの共用を起動前に確認し、干渉を避けられない場合は別PCか独立したVMで検証する。
既定の登録名では次のcommandになる。

```powershell
wsl.exe --terminate 'NixOS'
wsl.exe --distribution 'NixOS'
```

再ログイン後は、通常ユーザーで元のcheckoutへ戻る。
boot generationが配備したGit identityを確認し、暗号化済みのenrollment差分だけをcommitする。

```bash
cd ~/environment/dotfiles-wsl
git var GIT_AUTHOR_IDENT
git diff --check
git diff -- secrets/sops/assets/.sops.yaml secrets/sops/assets/secrets.json
git status --short
git add -- secrets/sops/assets/.sops.yaml secrets/sops/assets/secrets.json
git commit -m 'chore: hostの鍵登録'
git status --short
```

checkoutを変更したhostでは、bootstrapが表示する`cd`のpathを使う。
identityの確認やcommitが失敗した場合は、その原因を調べて直し、未commitのまま通常のrebuildへ進まない。
commit後のtracked working treeがcleanであることを確認する。

## 初回同期と適用

再ログイン後はboot generationの`nix-ld`を使える状態で、採用したAgent CLIを導入する。

```bash
dotfiles-install-agents
```

containerを選ぶhostでは、配備済みの短いcommandでupstream OCI imageを同期してから同じcheckoutを適用する。

```bash
dotfiles-sync-images
dotfiles-rebuild
```

containerを一つも選ばないhostには同期commandを配備しないため、CLIの導入後にbootstrapの表示どおり`dotfiles-rebuild`を実行する。
checkoutから別hostを明示して同期する入口は[OCI images](oci-images.md)にある。

初回boot generationのcontainer unitは、Docker cacheにimageがないため失敗することがある。
image同期後のrebuildでserviceを収束させる。
rebuildがWSL再起動を指示した場合は、表示された手順を完了してから認証と検証へ進む。
switchが非ゼロで終わった場合は、前世代がactiveだと決めつけず、[Rebuildの調査とrollback](rebuild.md#失敗時の調査)を使う。

## 認証と検証

採用したAgent clientを起動し、そのclientのlogin手順で認証する。
OMPを選ぶhostでは、[subscription login](agent-clients.md#omp-の-subscription-login)を使う。
GitHub accountはSOPSから配備されるため、`gh auth status`で確認し、別のホストのlogin sessionはコピーしない。
認証後は採用したclientで実際の接続を確認する。

```bash
dotfiles-doctor
systemctl --failed
git status --short
```

doctorの終了statusが0でも`warn`は残るため、[Doctorの結果](doctor.md#結果)でwarningを確認する。
初回構築の成功条件は、host keyによる復号、enrollment差分のcommit、必要なimageの同期、通常のrebuildの成功、再起動指示の完了、採用clientの認証と接続、doctorのfailure解消、cleanなtracked working treeである。
これらを実行していないホストは構築済みとして扱わない。

## 別ホストへの再現

tracked sourceと`flake.lock`はsystemとHome Manager設定の再現対象である。
Agent CLI本体はinstallerがupstreamから取得するため、取得した版は[Agent clientの確認手順](agent-clients.md)で別に記録する。
CLIのlogin session、host key、採用したcontainerの永続data、Windowsの資源とdistribution登録はsourceのcloneだけでは再現されない。
永続dataを引き継ぐ場合は、そのdataのbackupとrestoreを行い、空のdataでの初回起動をrestoreの成功とみなさない。
dataの所在、停止とexport、元のdistributionを消さないrestoreの受入条件は[データの復旧](recovery.md)に従う。

全host共通のCapabilityは[`profiles/workstation.nix`](../../profiles/workstation.nix)、host固有の選択は[`profiles/hosts/`](../../profiles/hosts)の`dotfiles.capabilities.enabled`で管理する。
RAM、CPU、disk、DNS、drive、VHD、distribution名のhost差は[Windows側の準備](doctor.md)で確認する。

次のenrollmentを始める前に、暗号化済み差分をcommitしたsourceを併用する全ホストへ同期する。
bootstrap前に中断する場合は、平文やhost keyを含めず、暗号化済み差分だけを外部媒体へ保存する。

```bash
git diff --binary -- secrets/sops/assets/.sops.yaml secrets/sops/assets/secrets.json \
  > /media/offline/host-enrollment.patch
```
