# ADR 0005: 配布する policy 本文を宣言からの生成物にする

**読み手:** Skill、subagent、client の一覧がどこを正本にしているかを判断する人。

## Status

Accepted

## Context

Skill の存在と依存は `skills/<id>/module.nix` の registry が宣言し、role と Skill の対応は当時の `agents/roles/` にある `routing.nix` が宣言し、client の能力分布は各 `agents/clients/<id>/module.nix` の mode が宣言する。同じ事実が、全 client へ配布する `agents/policy/AGENTS.md` の表と `docs/architecture/ai-tooling.md` の表にも手書きで存在する。

同期は検査が保っている。`agents/checks/deployment.nix` は routing に載った Skill 名と subagent 名が配布物の本文に現れることを要求し、加えて client の対応状況を述べた日本語の文と、廃止した経路の名称を固定文字列として照合する。散文が検査の期待値になっているため、client の能力を変えると宣言、配布物の散文、説明文書の表、検査の文字列を同時に直す必要がある。

標準は、一つの関心について正本を一箇所だけに置き、導出値を別の箇所へ保持してよいのは正本からいつでも再構築できる控えとして扱う場合に限ると定める（標準 `README.md` の「正本の単一」）。また、情報はその内容と最も強く同期する場所に一度だけ置くと定める（標準 `principles/README.md` の「情報の正本」）。

候補は三つあった。現状の継続、散文を正本として宣言を導出する形、宣言を正本として散文を生成する形である。一つ目は正本が複数ある状態を維持する。二つ目は、Skill の source と依存が Nix 評価の入力である以上成立しない。

配布層そのものを外部の同期ツールへ置き換える案も検討した。Tencent の teamai-cli は同じ関心を扱うが、配布先を命令的に書き換えるため、配備物と宣言 source の一致を根拠にする drift 検査と両立しない。また対象 client に OMP と Antigravity を含まない。採らない。

## Decision

`agents/policy/AGENTS.md` の Skill 一覧、subagent 一覧、Capability と入口 Skill の対応、client の能力表を、Skill registry、各 `SKILL.md` の frontmatter、subagent の frontmatter、Capability registry、client の mode 宣言から生成する。Skill と subagent をいつ使うかを述べる一文の正本は、それぞれの frontmatter の description とする。

`docs/architecture/ai-tooling.md` からは同じ対応表を削除し、正本の位置と現在値の取得法だけを残す。生成先を配布物に限るのは、agent が読む policy が単体で完結する必要がある一方、説明文書の読み手は正本を辿れるためである。

`agents/checks/deployment.nix` は、散文中の固定文字列と名前の存在を照合する検査をやめ、生成物が正本から再生成した内容と一致することで判定する。

## Consequences

Skill を増減するときに手で書く場所が `skills/<id>/module.nix` と `skills/<id>/skill/SKILL.md` の二つになり、配布物は再生成で追従する。client の能力を変えるときに手で書く場所は当該 client の mode 宣言だけになる。説明文書は対応表を持たないため、現在値は `nix eval` で取る。

生成物の再現性が検査の対象になる。廃止した経路の名称を検査が保持する必要はなくなり、その履歴は版管理履歴に委ねる。

生成した本文は控えであるため、配布物を直接編集しても正本は変わらない。
