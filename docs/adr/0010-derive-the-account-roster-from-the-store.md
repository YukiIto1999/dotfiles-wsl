# ADR 0010: 暗号化済み store を account roster の正本にする

**読み手:** 登録済み account をどこが持つかを判断する人と、secret store の形式を変える人。

## Status

Accepted

## Context

[ADR 0009](0009-declare-github-accounts-in-the-host.md) は roster を機構から host の宣言へ移した。しかし sops は値だけを暗号化して key の構造を平文で残すため、roster は最初から暗号化済み store が持っていた。`profiles/workstation.nix` の宣言はその写しであり、`docs/operations/secrets.md` が「roster と暗号化済み key を同時に変更する」という運用規律で二つの複製を同期させていた。手で同期する複製が二つある状態そのものが、この repository が排除している形である。

宣言側に account の ID を書くと、もう一つ弊害が出る。tree を読む人が、どの entry がどの account かという同一性の判断を要求される。機構が表すべき抽象は account であり、誰が登録済みかは data の事実である。

候補は三つあった。ADR 0009 の形を維持する案、key 構造だけを写した JSON index を commit して検査で一致を縛る案、store を Nix が native に読める形にして直接導出する案である。

一つ目は複製を残す。二つ目は複製を一つ増やして検査で埋める形で、解こうとしている問題と同じ構造になる。三つ目は複製が増えず、宣言した secret が store に無いという失敗自体が構造的に消える。Nix に YAML parser は無いが、sops は JSON を native に扱い、`builtins.fromJSON` は import from derivation を伴わずに評価時に読める。

## Decision

暗号化済み store を `secrets.json` とし、`secrets/sops/module.nix` が key 構造から secret path の一覧を `dotfiles.secrets.paths` として公開する。`identity/module.nix` はそこから GitHub account の roster を導出し、宣言側から account の ID と個数を除く。

`gh` の active user と既定 token になる account は、store の当該 entry に `primary` の key を置いて印を付ける。key の存在だけを読み、値は読まない。

## Consequences

account の増減は store の編集だけで完結し、module も profile も変わらない。tree のどこにも account の同一性が現れない。

登録済み account の把握は runtime で行う。`gh auth status` が hosts.yml から handle、active、scope を返すので、agent は環境に何が登録されているかを理解して使える。

store の編集は YAML から JSON になる。`.sops.yaml` の `path_regex` も JSON を指す。

この設計は、sops が値だけを暗号化して key を平文で残す性質に依存する。`encrypted_regex` や `mac_only_encrypted` で key 自体を隠す設定は採れない。key を隠す必要が生じた場合は、この記録を覆して別の導出経路を決める。
