# Orca からの client 起動

**読み手:** Windows の Orca から WSL の managed client を起動する運用者と、起動経路を変える実装者。

Orca は workspace、選択した client、PTY を持つ。WSL 側は、Orca が入力した command を `bash -l` が受け取り、`dotfiles-project-run` が project の devShell を開き、共通 runtime の wrapper が client を `agents.slice` の scope で起動する。この文書は、その各段の契約、Orca 側へ貼る値、実機での確かめ方を示す。

## 確認した起動の事実

Orcaの起動commandはargvではなく一行の文字列である。
採用中のsourceの[`buildAgentStartupPlan`](https://github.com/stablyai/orca/blob/a7927b28ce45cbb044add478d957abe36c99ccd8/src/shared/tui-agent-startup.ts#L42)はcommand overrideと既定commandから起動行を作り、clientのprompt injection形式に従ってquoteしたpromptか後続の入力を選ぶ。
この一行がPTYのshellへ入力として届く。
[`quotePortableUnixArg`](https://github.com/stablyai/orca/blob/a7927b28ce45cbb044add478d957abe36c99ccd8/src/shared/tui-agent-startup-shell.ts#L192)はsh、bash、zsh、fishに共通の形で引数をquoteする。

この環境の実測では、OMP の祖先は `/init`、`bash -l`、`dotfiles-agent-runtime` だった。Orca の設定画面は agent ごとに command override を持ち、保存先は Windows 側の `orca-data.json` の `.settings.agentCmdOverrides` である。確認した保存値では `agentCmdOverrides` は空だった。実際の CLI の `orca terminal create --help` も、`--command` は host が起動した shell へ入力される文字列だと示す。

確認したのは Orca の source と、この環境で動いていた一つの session であり、実行中の Orca の版と source の版の一致、override を設定した起動の実測は未確認である。

## 入口: `dotfiles-project-run`

```sh
dotfiles-project-run [--attr NAME] -- ABSOLUTE-EXECUTABLE [ARG...]
```

利用者が `direnv allow` した project の `.envrc` を、信頼の記録として使う。入口は `direnv status --json` を読み、見つかった `.envrc` が許可済み(`allowed` が 0)のときだけ、その `.envrc` がある directory を flake として `nix develop --no-update-lock-file --no-write-lock-file DIRECTORY#NAME` で開く。`NAME` は既定で `default` である。devShell の中で `ABSOLUTE-EXECUTABLE` を絶対 path で起動し、Orca が後ろへ足した引数はそのまま渡る。

次の場合は executable を起動せず、非ゼロで終わる。host の PATH や基礎環境へは戻らない。

- `.envrc` が無い、未承認、拒否、`.env`、direnv の状態を読めない。
- devShell が無い、評価に失敗する、lock が更新を要する。
- 実行ファイルが絶対 path でない、実行できない、path に `=` を含む。
- devShell 名が識別子でない、project の path が flake 参照として別の意味になる文字(`#`、`?`、`%`)を含む。

`direnv exec .` を使わないのは、`Denied` のときに基礎環境を返すためである。承認の判定は `direnv allow` と同じ記録を読むので、未承認の project は `direnv allow` で承認する。承認の対象は `.envrc` の内容であり、`use flake` が読む `flake.nix` の内容ではない。承認前に project を確認する。

`nix develop` は、実行前に `TMP`、`TMPDIR`、`TEMP`、`TEMPDIR` を新しい `nix-shell` directory へ書き換え、devShell の `PATH` の後ろへ host の `PATH` を足す(Nix 2.34.8 の `src/nix/develop.cc`)。入口は呼び出し前の `TMPDIR` 系の状態(未指定、空文字列、値)を `env` で戻してから executable を起動する。これがないと、管理 scratch の条件である「`TMPDIR` が未指定」を runtime が判定できない。

## Orca へ貼る値

```sh
dotfiles-orca-config          # 選択した managed client ごとに「Orca の agent ID<TAB>command override」
dotfiles-orca-config --json   # agentCmdOverrides の JSON
```

出力は貼り付ける値だけで、Windows の file も Orca の設定も変えない。適用は Orca の Settings > Agents で対象 agent の command override に値を貼る。この Windows 側の設定変更は、利用者の承認を得てから行う。`orca-data.json` を Orca の実行中に手で編集しない。

command override を設定すると、その agent のどの workspace でも `dotfiles-project-run` を通る。`.envrc` を承認していない project では client が起動しないので、project ごとに承認してから使う。

## 検証

自動の検査は、起動された client が見る環境と、拒否後に残る状態を読む。

| 検査 | 確かめること |
|---|---|
| `toolchain-project-run` | 承認済みの directory の devShell だけを開き、承認の欠落、拒否、devShell の失敗で client を起動せず host の PATH へ戻らず、`TMPDIR` 系の状態、argv、終了値が保たれる |
| `toolchain-execution-policy` | cache の既定、明示値の優先、project の Cargo 設定の優先、checkout ごとの build-dir |
| `supervise-child-ownership` | 子と遅い孫の終了確認、session 取消と操作の取消の区別、保持する lock descriptor |
| `agent-runtime-behavior` | 台帳、GC root、scope、終了の順序、台帳と reaper lock の待ちの上限 |
| `agent-runtime-wrapper`、`agent-runtime-protect` | wrapper の連鎖と保護の取得、世代変更と模擬 GC 後の読取済み Skill の利用継続、全子終了後の解放、失敗時に root を残さないこと |

自動の検査は direnv、nix、systemd、Nix daemon を模している。実物での確認は次の手順で行う。

### 実機 smoke

隔離した一時 directory を使い、実 client、既存 session、Windows の設定には触れない。

1. 承認とdevShell。一時Git projectに`devShells.<system>.default`と`.envrc`の`use flake`を用意し、inputの`flake.lock`も作って両方を追跡する。`XDG_DATA_HOME`を一時directoryに向け、承認前は`dotfiles-project-run -- "$PROBE"`が非ゼロでprobeを起動しないことを確かめる。`direnv allow`の後はdevShellのtool、argv、呼出し前の`TMPDIR`系の状態、終了値をprobeに記録させる。存在しないdevShell名でも非ゼロでprobeを起動しないことを確かめる。
2. PTY と argv。`script -qefc 'dotfiles-agent-runtime fixture-client "$PROBE" "a b" "" "ユニコード"' /dev/null` の中で、`PROBE` が `[ -t 0 ]`、argv、cwd、終了値を記録すること。cwd は空白と Unicode を含む。
3. scope と取消。`PROBE` が子と孫を残して待つとき、`systemctl --user list-units 'dotfiles-agent-*.scope'` に scope があり、launcher へ `SIGTERM` を送ると、戻った時点で scope の `cgroup.procs` が空、`~/.cache/dotfiles-wsl/sessions` が空であること。`SIGINT` では session が続くこと。同時に走らせた別の session が影響を受けないこと。
4. GC root。自分が作ったsession directoryの`roots`だけを調べ、起動した実体と依存のstore pathを指すこと、終了後にそのsession directoryが無くなることを確認する。global GCや全rootの走査を検証の代わりにしない。
5. Orca 経由。`orca-ide terminal create --worktree active --command 'dotfiles-project-run --attr default -- "$PROBE"' --json` で作った terminal の出力を `orca-ide terminal read` で読む。これは command override を通る既定の起動の代わりではない。override を適用した後は、`orca-ide worktree create --name NAME --agent omp --json` で既定の経路を実測する。

この手順の結果を、既定経路の実測として扱うのは、override を適用して手順 5 の後半を実行した後だけである。

## 未確認

- Orca の command override を設定した既定の起動、`terminal wait --for tui-idle` などの状態検出が `dotfiles-project-run` を経由した process 構成でも働くか。
- `.envrc` の承認が `flake.nix` の変更を信頼として含まない範囲の運用上の十分さ。
