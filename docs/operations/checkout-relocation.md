# checkout の移動

**読み手:** 目的の作業をやり遂げたい運用者。作業中に読む。

`dotfiles.workstation.dotfilesDir` の既定値は `dotfiles.workstation.environmentDir` の下の `dotfiles-wsl`、つまり `~/environment/dotfiles-wsl` である。以前の既定値だった `~/dotfiles-wsl` に checkout を置いた host は、この手順で移す。architecture-standard や orca の checkout のように、dotfiles と一緒に手入れする repository も同じ directory へ移す。

checkout の場所を覚えているものは四つある。current generation が持つ command と out-of-store symlink、`/etc/nixos` と root の Git `safe.directory`、project memory の bank、omp の session の置き場である。project memory の bank と omp の置き場はどちらも path から決まるため、移しただけでは新しい path から過去の記憶と session が見えなくなる。手順はこの四つを順に付け替える。

## 始める前に

移す checkout を cwd にしている agent の session をすべて閉じる。作業に使う shell と agent は、移す checkout の外、例えば home から起動する。旧 checkout を退避すると、その中で動いていた process は cwd を失い、command を起動できなくなる。

旧 checkout で main を取り込み、新しい場所が宣言されていることを確かめる。

```bash
cd ~/dotfiles-wsl
git pull --ff-only
nix eval --raw .#nixosConfigurations.<host-id>.config.dotfiles.workstation.dotfilesDir
```

移す repository ごとに、旧 path の project memory の bank ID を控える。bank ID は Git の directory から決まるので、移した後では求められない。

```bash
dotfiles-memory project ~/dotfiles-wsl
```

## 新しい checkout を用意する

旧 checkout から clone し、`origin` を旧 checkout と同じ URL に戻す。clone は Git が管理する file だけを持つ。

```bash
git clone --no-hardlinks ~/dotfiles-wsl ~/environment/dotfiles-wsl
git -C ~/environment/dotfiles-wsl remote set-url origin "$(git -C ~/dotfiles-wsl remote get-url origin)"
git -C ~/environment/dotfiles-wsl fetch origin
```

Git の管理外の file は `git -C ~/dotfiles-wsl status --short --ignored` で一覧にし、必要なものだけを移す。作業の記録を置く `.docs/` があれば移す。`.direnv/`、`.codex/`、`result` は direnv、Home Manager、build が作り直す。`.zvec-grep/` は旧 path を root として記録しているため、移しても使えない。

```bash
cp -a ~/dotfiles-wsl/.docs ~/environment/dotfiles-wsl/
```

作業日誌の repository をまだ clone していなければ、[作業日誌](agent-journal.md)の前提に従って `~/environment/agent-journal` に clone する。

## generation を切り替える

旧 checkout を退避する前に rebuild する。current generation の `dotfiles-rebuild` は旧 path を内部に持ち、どこから実行してもその checkout を build するので、旧 checkout がないと動かない。新しい generation は新しい path を指すが、そこは用意済みなので、out-of-store symlink は切れない。

```bash
dotfiles-rebuild
```

`/etc/nixos` と root の `safe.directory` を新しい path に付け替える。旧 path が登録されていなければ、最後の command は外すものがないため終了コード 5 で終わる。

```bash
sudo ln -sfn ~/environment/dotfiles-wsl /etc/nixos
sudo git config --global --add safe.directory ~/environment/dotfiles-wsl
sudo git config --global --unset-all safe.directory "^$HOME/dotfiles-wsl\$"
```

旧 checkout を退避し、ほかの repository を移す。

```bash
cd ~
mv ~/dotfiles-wsl ~/dotfiles-wsl.old
mv <旧 path> ~/environment/<名前>
```

## 記憶を移す

新しい path で agent を起動する前に、project memory の bank を複製する。agent を先に起動すると、保存の時点で新しい bank が作られ、複製は失敗する。複製は既存の bank を宛先にできないからである。

```bash
dotfiles-memory project ~/environment/dotfiles-wsl
```

控えた旧 bank ID と、この新しい bank ID を渡して複製する。複製は LLM を呼ばず、document、fact、observation、bank の設定を移す。進み具合は複製元の bank で確かめる。

```bash
clone_bank() {
  local src=$1 dst=$2 api=http://127.0.0.1:3111/v1/default/banks op
  op=$(curl -fsS -X POST "$api/$src/clone?target_bank_id=$dst&include_data=true&include_bank_config=true&include_history=false" | jq -r .operation_id)
  until [[ $(curl -fsS "$api/$src/operations/$op" | jq -r .status) =~ ^(completed|failed)$ ]]; do sleep 2; done
  curl -fsS "$api/$src/operations/$op" | jq -c '{status, result_metadata}'
  for bank in "$src" "$dst"; do
    curl -fsS "$api/$bank/stats" | jq -c '{bank_id, total_documents, total_nodes, total_observations}'
  done
}
clone_bank <旧 bank ID> <新 bank ID>
```

document、node、observation の数が複製元と一致すれば移せている。semantic link は複製先の embedding から作り直されるため、数が減ることがある。旧 bank が存在しない repository は、記憶がないので飛ばす。

## 新しい checkout から確かめる

新しい path で direnv を許可し、rebuild と doctor を実行する。zvec-grep の index は旧 path を root にしているため、doctor の前に作り直す。

```bash
cd ~/environment/dotfiles-wsl
direnv allow
zg index ~/environment/dotfiles-wsl --embedding local/potion-code-16m-v2 --mode direct
dotfiles-rebuild
dotfiles-doctor
readlink /etc/nixos
```

## omp の session を付け替える

旧 path の session は、omp の置き場に旧 path の名前のまま残る。新しい path の shell で `omp --resume <session の ID>` を実行すると、omp が付け替えるかを尋ねる。`Y` と答えると、session file と関連 file が新しい path の置き場へ移り、移る前の場所が `previousSessionFiles` に記録される。付け替えるまで、その session は `omp --resume` の一覧で `Tab` を押した全 project 表示にだけ現れる。`omp stats` は、付け替えた session の過去の使用量を旧 path の名前で集計したままにする。

Claude Code、Codex、VS Code の拡張も project を path で記録している。新しい path は、それらには未登録の project として扱われる。

## 旧 checkout と旧 bank を消す

新しい path から記憶を呼び出せ、doctor が通ることを確かめてから消す。消すと戻せない。

```bash
rm -rf ~/dotfiles-wsl.old
curl -fsS -X DELETE http://127.0.0.1:3111/v1/default/banks/<旧 bank ID>
```
