# ADR 0011: OMP を managed release で更新する

**読み手:** agent client の入手経路を判断する人と、client を追加または移行する人。

## Status

Accepted

## Context

agent client の更新経路は三つあった。claude と antigravity は upstream の installer script を叩き、codex と opencode は GitHub release の asset を取得して `~/.local/share/dotfiles/agents/<client>` へ atomic に publish する。OMP だけが flake input として pin され、更新は `nix flake update omp` と `dotfiles-rebuild` を人が実行することを要した。日次の `dotfiles-agent-autoupdate.timer` は前二者しか更新しないため、OMP の version は人の記憶に従属していた。実測では pin が `18.0.11` で、upstream の最新は `18.1.13` だった。

upstream の `can1357/oh-my-pi` は、platform ごとの単一実行 file を release asset として publish する。`omp-linux-x64` は動的リンクの ELF で、この host では `programs.nix-ld.enable` が供給する `/lib64/ld-linux-x86-64.so.2` で解決でき、実測で `omp/18.1.13` を返した。managed release で運用している opencode の binary も同じ interpreter で動いている。release API の asset record は `digest` を持つため、既存経路の digest 検査もそのまま成立する。

候補は三つあった。flake input を維持して人が bump する案、`flake.lock` を timer が bump して rebuild する案、既存の `github-release` 経路に載せる案である。

一つ目は、更新されない状態が既定になる。二つ目は四番目の更新経路を増やし、timer が repository を書き換え、無人の generation 切替と passwordless sudo を要する。三つ目は既存の mechanism をそのまま使い、更新経路が一つ減る。ただし `github-release` 経路は asset が tar.gz であることを前提にしており、単一 file の asset を扱えなかった。

## Decision

OMP を `github-release` と `updateOwner = "dotfiles"`、`layout = "single-binary"` へ移し、`flake.nix` の `omp` input と client 側の Nix package 定義を削除する。

download の形は `assetFormat` として client 契約に加える。`tar.gz` は従来どおり展開して検査し、`raw` は download した file 自体を entrypoint として payload へ置き、archive 経路と同じ mode、tree 検査、probe、publish へ渡す。raw asset は archive の member 検査に相当する境界を持たないため、`single-binary` layout 以外との組み合わせを Nix の型述語と installer の両方で拒む。entrypoint も path 成分を持てない単一の名前に限る。

## Consequences

OMP は他の client と同じ timer で更新され、release の digest 検査、atomic publish、retention、rollback をそのまま得る。`~/.local/bin/omp` は managed release tree を指す symlink になり、Nix store の実体ではなくなる。

version の pin は `flake.lock` から消え、OMP は upstream の latest に追従する。特定 version へ固定したい場合は managed release の retention から前の release へ戻すか、client 契約側に version の指定を足す判断が必要になる。

実行は `programs.nix-ld` が供給する loader に依存する。nix-ld を無効化すると OMP は起動しない。

`nix-package` の install kind は、これでどの client も使わない分岐になる。client 契約の `package` option と `home.packages` への注入もあわせて削除し、client 契約は installer script と GitHub release の二経路だけを表す。
