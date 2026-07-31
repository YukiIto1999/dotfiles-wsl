# ADR

ADR は、構成を決めた時点の背景、選択肢、決定、影響を残す。現在の操作は[手順](../README.md#手順--operations)、現在の責務と境界は[構造](../README.md#構造--architecture)を参照する。

状態が `Accepted` の ADR を変更するときは本文を過去にさかのぼって書き換えず、新しい ADR で置き換える。新しい ADR には置き換える文書へのリンクを記載し、旧 ADR の状態を `Superseded` に変更する。

## 一覧

- [0001. 関連ファイルの隣接配置と単一宣言](0001-colocation-and-single-declaration.md) — 設定、template、package を所有 module の近くに置き、同じ値を複数箇所へ転記しない。
- [0002. 運用コマンドの設定生成](0002-generated-ops-commands.md) — `dotfiles-*` command を Nix の宣言から生成し、対象や依存を current generation に固定する。
- [0003. local skill のシンボリックリンク配備](0003-local-skills-live-symlink.md) — local skill は checkout への live symlink、plugin skill は固定した store path から配備する。
- [0004. MCP target 名](0004-mcp-target-naming.md) — gateway が公開する target 名を package 名から分離し、tool prefix の安定した contract とする。
- [0005. agentmemory lifecycle hooks の全 CLI 共通配備](0005-agentmemory-lifecycle-hooks.md) — CLI ごとの lifecycle 機構から観測を自動取得し、MCP だけに依存しない記憶経路を持つ。
- [0006. agentmemory の LLM provider](0006-agentmemory-llm-provider.md) — 要約と consolidation に外部 provider を使い、credential と送信境界を明示する。
- [0007. SOPS 鍵の enrollment と通常更新を分離する](0007-sops-key-enrollment.md) — host key、recovery key、recipient の移行を通常の rebuild から独立した transaction にする。
- [0008. WSL の再起動要否を cold-start manifest で判定する](0008-wsl-cold-start-manifest.md) — live switch と WSL cold start を変更内容から判定する。
- [0009. rebuild を immutable candidate の回復可能な apply に分ける](0009-rebuild-effect-routing.md) — source、candidate、activation、回復を固定した transaction として扱う。
- [0010. doctor は current generation の宣言と実状態の収束を検査する](0010-current-generation-doctor.md) — mutable な checkout ではなく current generation の manifest を期待値にする。
- [0011. doctor は result core から human / JSON report を生成する](0011-doctor-result-report.md) — 検査結果と表示を分離し、status、outcome、phase の contract を定める。
- [0012. upstream OCI image の取得を明示的な同期操作に分ける](0012-explicit-oci-image-sync.md) — registry 取得を activation から分離し、固定 digest への同期を明示操作にする。
- [0013. doctor は OCI image と稼働 container の収束を同じ観測境界で検査する](0013-oci-runtime-convergence.md) — receipt、Docker cache、稼働 container を同じ generation の期待値と比較する。
- [0014. OCI image の同期を activation の明示的な前提条件にする](0014-oci-activation-readiness.md) — candidate または回復対象の image が揃うまで activation を開始しない。
- [0015. downstream の GET body を MCP session の生存基準にする](0015-mcp-session-lifecycle.md) — 最後の request 時刻ではなく response body の生存で session を保持し、蓄積を止める。
