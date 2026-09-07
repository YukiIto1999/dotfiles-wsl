# ADR 0012: client 更新の失敗を client 単位に隔離する

**読み手:** agent client の更新の失敗の見え方を判断する人と、maintenance timer の観測を変える人。

## Status

Accepted

## Context

`dotfiles-agent-autoupdate.service` は三日続けて `ExecMainStatus=28` で終わっていた。journal は Sep 5、6、7 のいずれも `== agy` の直後に `curl: (28) Resolving timed out after 10002 milliseconds` を記録し、そこで log が途切れている。`install-agents.sh` の `fail` が process ごと `exit 1` するため、antigravity の名前解決が一度失敗するだけで、後続の claude、codex、opencode の更新も止まっていた。実際に更新が成功した最後の記録は Sep 4 である。手元の `getent hosts antigravity.google` は成功するので、恒久的な障害ではなく、一時的な失敗が全 client の更新を人知れず止め続けていた。

失敗が続いたこと自体も観測されていなかった。`agents/module.nix` は `project-cache-gc` と `resource-reaper` の timer だけを `dotfiles.health.observations` に登録し、autoupdate を登録していなかった。`dotfiles-doctor` は 319 件を pass と報告しながら、三日間の失敗を示さなかった。

観測を足すだけでは足りないことも実測でわかった。systemd の `Result` は `switch-to-configuration` の reset-failed で `success` へ戻り、`dotfiles-rebuild` の後には失敗した run が成功と区別できなくなる。実測時点の unit は `Result=success` と `ExecMainStatus=28` を同時に示していた。既存の `systemd-timer` 観測は `Result` だけを読むため、この状態を pass と判定する。

隔離の候補は三つあった。失敗を retry で埋める案、client ごとに独立した service と timer に分ける案、一つの process 内で client ごとに失敗を閉じる案である。retry は名前解決の失敗を遅らせるだけで、他 client の更新が一つの client に従属する構造を残す。unit の分割は unit と log の数を client 数に比例させ、client 一覧の正本を systemd 側にも作る。client の更新は互いに独立で、共有する transaction を持たないため、隔離の境界は process より内側に置ける。

## Decision

manifest の client ごとの install を subshell に閉じ、失敗した client 名を集めて最後に `FATAL: client install failed: <names>` として報告し、非ゼロで終える。install kind と client 名の妥当性検査は top-level に残し、不正な manifest が curl の前に落ちる不変条件を保つ。

subshell は errexit と後片付けの EXIT trap を自前で持ち直す。bash は subshell へ親の EXIT trap を渡さず、`set +e` した親からは errexit も継承する。これを省くと stage が残り、payload の検査が無効化される。

`agents/maintenance/autoupdate` を doctor の観測に登録する。あわせて `systemd-timer` の観測は `Result` に加えて `ExecMainStatus` を読み、最後の起動が非ゼロで終えた maintenance job を失敗として報告する。

## Consequences

一つの upstream の障害は、その client の更新だけを止める。失敗した client 名は service の終了時に一度だけ報告され、timer の失敗として doctor から見える。

観測の強化は autoupdate に限らず、fstrim、nix-gc、project-cache-gc、resource-reaper、container の timer にも同じ判定を与える。rebuild 直後でも、最後の起動が失敗した maintenance job は pass にならない。

隔離の境界は process ではなく subshell である。client 間で state を共有する設計に変えるなら、この境界を見直す必要がある。

検証は `agent-installer-behavior` が持つ。先頭 client の失敗が後続 client の publish を止めないこと、失敗した client 名だけが報告されること、失敗した client の stage が残らないことを実測する。`doctor-runtime` は `Result` が success でも最後の終了 status が非ゼロなら fail になることを実測する。
