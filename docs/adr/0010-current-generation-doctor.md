# 0010. doctor は current generation の宣言と実状態の収束を検査する

## 状態

Accepted

## 背景

従来の `dotfiles-doctor` は mutable な checkout、`share/AGENTS.md` の表、実行時の PATH を別々の期待値として扱っていた。system profile が current generation と異なる状態や、存在しない systemd unit を成功扱いできた。skill は全 CLI の配置先を一つの集合へまとめていたため、ある CLI の欠落を別の CLI が補うこともあった。

MCP 検査は `initialize` で session ID を得た後、初期化完了通知と session の破棄を行わずに `tools/list` を1回呼んでいた。これは negotiated protocol version を後続 request に渡し、処理後に session を終了する Streamable HTTP の lifecycle を満たさない。

`nix flake check` は source から artifact を生成できることを検査するが、activation 後の system profile、systemd、root 所有の host key、upstream 配布の CLI、常駐 MCP gateway の状態は検査できない。build-time check だけでは runtime の収束を保証できない。

## 決定

評価済み NixOS / Home Manager 設定から version 2 の JSON manifest を生成し、current system closure の `etc/dotfiles/doctor.json` に収録する。doctor は `/run/current-system/etc/dotfiles/doctor.json` だけを期待値として読み、checkout と Markdown の表を参照しない。

unit と managed file の health 宣言は、対象を定義する module に隣接させる。CLI と skill の一覧は既存の `my.clis` と `allSkills` から導出する。manifest は次を保持する。

- current、booted、system profile の論理パス
- 必須 systemd unit
- runtime file と比較する immutable source
- CLI ごとの固定 binary path、rules、skills、agent file 名、gateway file
- SOPS metadata probe と、旧 home key のパス、移行状態を表す `warn` / `reject` policy
- current generation の `wslview` と Windows 側 `cmd.exe` の固定パス
- MCP URL、target、要求 version、許容する negotiated version の一覧

doctor は system profile と実行中の doctor が current generation を指すことを canonical path で確認する。WSL の状態は ADR 0008 の classifier を使い、effect が `switch` の場合だけ成功とする。unit は待機せず `LoadState=loaded` と `ActiveState=active` を要求する。

SOPS host key は一般ユーザーから読めない。固定した `/var/lib/sops-nix` と `key.txt` の UID、GID、mode だけを返す immutable な root probe を生成し、その引数なし command だけを sudo rule に登録する。probe は鍵本文を開かない。directory は root `0700`、key は root `0400` を要求する。home 側の旧 age key は移行中の `warn` では警告し、host key とオフライン復旧鍵の復号実測後に `reject` へ切り替えて失敗にする。

agents 対応 CLI は directory の存在だけでなく、`share/agents` と各 CLI の変換規則から導出した全ファイル名を検査する。`wslview` は current generation の system path が宣言した store source を指すこと、PATH の解決先がその system path であることを要求する。さらに `cmd.exe /d /c exit 0` を5秒上限で実行し、WSLInterop の binfmt を含む起動経路を検査する。browser や Windows application は開かない。

MCP は一つの session で次を順番どおり実行する。

1. `initialize` response の JSON-RPC ID、tools capability、session ID、negotiated protocol version を検証する。
2. session ID と negotiated version を付けて `notifications/initialized` を送る。
3. 同じ header で `tools/list` を全ページ取得し、各 target の prefix を持つ tool を確認する。
4. 正常終了、検査失敗、INT、TERM のいずれでも同じ冪等 cleanup から session を `DELETE` する。

JSON と SSE の両 response を受け付ける。SSE は event 境界を保ち、notification を読み飛ばして要求 ID に対応する response を選ぶ。request は5秒、pagination は100ページで上限を設ける。この構成では gateway を所有しているため、session `DELETE` は 2xx 以外を失敗とする。

## 影響

flake check は宣言から artifact を作れること、doctor は current generation の宣言と外部状態が収束したことを担当する。両者は代替関係ではない。

doctor は checkout の clean 状態、secret の値、AI CLI 本体の配布元・内容・版と認証状態、skill 本文、agent file の内容、agentmemory の保存内容を保証しない。これらは rebuild の preflight、enrollment と bootstrap の復号確認、各 application の診断に分ける。

manifest は秘密値を持たず、runtime の期待値を増やす独立した設定ファイルではない。既存の Nix 宣言から生成するため、doctor 専用の inventory を手で同期しない。`doctor-manifest-contract` check は実配備 manifest を読み、Home Manager が生成する agent file 名、Codex project config、SOPS policy、WSL interop 宣言との一致を固定する。手書き fixture は runtime の失敗行列だけを担当する。

## 一次資料

- [MCP lifecycle 2025-06-18](https://modelcontextprotocol.io/specification/2025-06-18/basic/lifecycle)
- [MCP transports 2025-06-18](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports)
