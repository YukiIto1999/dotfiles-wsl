# 運用

作業中に読む手順をまとめる。構成の理由は[設計](design.md)、秘密情報は[secrets](secrets.md)と[SOPSの鍵](sops-enrollment.md)、データの引継ぎは[データの復旧](recovery.md)にある。

## 新しいPCへの導入

1. Windowsで NixOS-WSL の公式 release（x86_64、このrepoと同じ 26.05 系列）を取得し、SHA-256 を照合して import する。登録名と保存先は空いているものを使う。

   ```powershell
   wsl.exe --import 'NixOS' 'D:\WSL\NixOS' .\nixos.wsl --version 2
   wsl.exe --distribution 'NixOS' --user nixos
   ```

2. 初期imageにはGitとflakeが無いので、一時的なshellで clone する。

   ```bash
   export NIX_CONFIG=$'experimental-features = nix-command flakes'
   nix shell nixpkgs#git --command bash
   mkdir -p ~/environment && git clone https://github.com/YukiIto1999/dotfiles-wsl ~/environment/dotfiles-wsl
   cd ~/environment/dotfiles-wsl
   ```

3. host を選ぶ。`hosts/<host>.nix` の file 名が host 名になる。新しい host は既存の file を写して、WSLの資源・drive・登録名を書き換え、信頼できる環境で commit しておく。
4. [SOPSの鍵](sops-enrollment.md#新しいhostの登録)に従って host key を作り、recipient に加える。復号できることを確かめてから次へ進む。
5. 手順2で開いた git 入りの shell で、利用者のまま最初の世代を作り、WSLを再起動する。root で checkout を読むと、git が所有者の違いを理由に拒否する。

   ```bash
   nixos-rebuild boot --sudo --flake ".#<host>"
   ```

   ```powershell
   wsl.exe --terminate 'NixOS'
   ```

6. 再ログイン後、enrollment の差分（`secrets/sops/assets/.sops.yaml` と `secrets.json`）を commit し、`dotfiles-rebuild` で HEAD を適用する。
7. `omp` を起動して `/login` で各providerへログインする（subscription の OAuth）。`gh auth status` で GitHub account を確かめる（tokenはsopsから配られる）。
8. `dotfiles-doctor` の FAIL が無いことを確かめる。WARN は表示された操作で対処するか、理由が分かっていれば残してよい。

Windows の `.wslconfig` はこのrepoからは書き換えない。`dotfiles-wsl-config` が表示する値を自分で反映する。

## 変更と適用

1. checkout で変更し、`nix flake check` を通して commit する。
2. `dotfiles-rebuild` を実行する。既定では commit 済みの HEAD を build して切り替える。共有 checkout に他 session の未 commit の変更があっても入らない。未 commit の変更を試すときは `--worktree` を付ける。
3. 表示された closure の差分と、WSLの再起動が必要かの案内を確かめる。`/etc/wsl.conf` が変わったときだけ、作業中の session が無い時に `wsl.exe --shutdown` する。
4. service、timer、slice の宣言を消す変更では、switch がそれらを止める。slice を止めると、その中で動いている command（他 session の build や検証）も止まる。消す前に `systemctl --user status <slice>` で中の処理が無いことを確かめ、残っていれば宣言を一度残して、中が空になってから消す（2026-11 の切替で、他 session の走行が2つ止まった）。

| 目的 | command |
|---|---|
| build だけして差分を見る | `dotfiles-rebuild build` |
| 次回のWSL起動で切り替える | `dotfiles-rebuild boot` |
| 直前の世代へ戻す | `dotfiles-rebuild rollback` |

方針（`agents/AGENTS.md`、`agents/RULES.md`）と local skill（`agents/skills/`）の本文は、編集すれば次の読込から効く。skill を追加・削除したときと、Nix の宣言を変えたときだけ rebuild する。

## 更新

- flake input: `nix flake update [INPUT]` → `nix flake check` → commit → `dotfiles-rebuild`。
- agent client（omp、claude、codex、opencode、agy）: `dotfiles-agent-update.timer` が毎日 client ごとの profile（`~/.local/state/nix/profiles/<client>`）を最新へ更新し、起動確認に失敗した client は元へ戻す。手動では `systemctl --user start dotfiles-agent-update.service`。profile が無い間は flake input `llm-agents` の固定版で起動する。
- architecture-standard の skill: `dotfiles-standard-sync.timer` が毎日公開版を取り込む。すぐに取り込むときは `dotfiles-standard-sync`。

## 不調の調べ方

まず `dotfiles-doctor` を実行する。各項目は対処の操作を示す。

- **新しいWSL端末が開かない・固まる**: doctor の `vmbus_alloc_ring` と stuck Relay を見る。guest の memory に大きな連続領域が無いと、新しい接続の ring を確保できず Relay が待ち続ける。不要な session を閉じて memory を空ける。直らなければ作業中の session が無い時に WSL を再起動する。Windows Update の停止は WSL 側からは操作しない。
- **memory が逼迫する**: `systemd-cgtop -m` で大きい cgroup を探す。agent の session は `agents.slice` の scope にあり、上限を超えるとその中で OOM が起き、systemd-oomd が pressure の高い cgroup を止める。
- **MCP の tool が使えない**: OMP が server を必要時に起動する（`/mcp` で状態を確認、`/mcp reload` で設定を読み直す）。GitHub の token は `/run/secrets` の file から server の起動時に読む。
- **記憶が返らない・保存できない**: `curl http://127.0.0.1:3111/health` と `systemctl status docker-hindsight.service`。保存は Hindsight 自身の LLM 抽出を通るため、その provider の利用枠が尽きると `retain_failed` になる。
- **日誌・収穫が失敗する**: `journalctl --user -u dotfiles-agent-journal -n 50`。model の認証（401）か利用枠（429）かを区別する。401 は、OMP の認証 DB（`~/.omp/agent/agent.db`）に残った古い key が先に選ばれて起きることがある（2026-11 に OpenCode Go で発生）。古い資格情報を OMP の認証設定から外す。

## 旧構成からの移行（2026-11 の再設計）

再設計より前に起動した OMP session は、開始時に読み込んだ hook と MCP の接続先（gateway）を持ち続ける。gateway は切替で止めたので、その session では MCP が使えない。
各 session で `/exit` してから `omp --resume` すると新しい構成で続きから再開する。MCP だけなら `/mcp reload` でもよい。
旧 session の停止 hook が呼ぶ `dotfiles-agent-gate` と、旧方針が指示する `dotfiles-agent-verify`・`dotfiles-workload-run`・`dotfiles-capped-run` は、何もしないか引数の command をそのまま実行する互換 command として残してある（`agents/transition.nix`）。
`dotfiles-doctor` が旧 runtime の session が無いと示したら、`agents/transition.nix` を削除して rebuild し、旧 cache（`~/.cache/dotfiles-wsl`、約 80 GB）と旧 client の profile（`~/.local/share/dotfiles/agent-profiles`）を消す。
