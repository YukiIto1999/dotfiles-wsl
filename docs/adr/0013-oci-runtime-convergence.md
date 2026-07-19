# 0013. doctor は OCI image と稼働 container の収束を同じ観測境界で検査する

## 状態

Accepted

## 背景

ADR 0012 は upstream image の取得を明示的な同期 transaction に分けた。ただし receipt の成功だけでは、現在の Docker cache に同じ image が残っていることや、稼働 container がその image を使っていることを保証できない。Nix が `imageFile` から load する agentmemory は upstream receipt の対象外であり、registry digest だけを共通の期待値にはできない。

doctor manifest v3 には OCI inventory がない。rebuild も v3 を既定値として扱い、schema v2 の rollback だけを特別扱いしていた。この分岐では、未定義 schema や破損 manifest の doctor を既知の protocol だと仮定して実行してから report failure にする。

## 決定

doctor manifest を version 4 にする。`my.ociImages` から image ID、取得責任、container、systemd unit、image reference、repository、digest、`imageFile` を生成する。Docker health unit、同期 state root、Docker command、同期 status command も current generation の immutable manifest に固定する。doctor 専用の手書き inventory は作らない。

Nix 生成 image は system closure の build 時に Docker archive を検証する。archive は単一 image の `manifest.json`、期待する `RepoTags`、安全な `Config` member 名を持たなくてはならない。Config の raw bytes の SHA-256 が Config filename と一致した場合だけ、`sha256:<Config hash>` を期待 image ID とする JSON sidecar を Nix store に生成する。doctor manifest はこの sidecar を参照する。

system phase は OCI image sync の state directory と lock の owner、mode、link count を検証し、shared lock を取得する。lock が不正または未初期化なら失敗、exclusive sync が実行中なら `blocked` とし、Docker と同期 status commandを実行しない。shared lock は image、container の観測が終わるまで保持する。

Docker health unit が成功した場合だけ、同じ generation の `dotfiles-sync-images --status` を期限付きで実行する。これは upstream receipt、manifest hash、local image ID、Docker cache の一致を検査する。その後、各 image を個別に観測する。

- upstream image は `docker image inspect` の `RepoDigests` に、manifest の `repository@digest` が含まれることを要求する。
- Nix 生成 image は immutable sidecar の image reference と `imageFile` が manifest と一致し、image reference の local image ID が sidecar の期待 image ID と一致することを要求する。
- image ごとの観測 ID は同じ doctor 実行中だけ保持し、稼働 container との比較に使う。期待 ID 自体は build artifact に固定する。

active phase は image と対応する container unit が成功した場合だけ `docker container inspect` を実行する。container が稼働中で、`.Image` が system phase で得た local image ID と一致した場合だけ成功とする。一つの image failure は別 image の観測を止めない。Docker、同期 status、systemd の probe は manifest の system timeout で打ち切る。

check ID は `system.oci.lock`、`system.oci.sync`、`system.oci.image.<id>`、`active.oci.container.<id>` とする。report schema は version 1 のまま維持し、`manifestSchemaVersion` だけを 4 にする。

rebuild は doctor manifest を実行前に単一 JSON document として読む。forward candidate は schema v4 だけを activation 前に受理する。rollback target は schema v4 / v3 の JSON protocol と schema v2 の legacy adapter だけを受理する。欠落、破損、複数 JSON document、未定義 schema の doctor は実行しない。verification 中にこの不整合を検出した場合は `doctor.manifest` を receipt の失敗 ID にする。

## 影響

明示 sync の receipt、Nix archive 由来の期待 image ID、Docker cache、稼働 container を別の証拠として診断できる。receipt が古くても偶然 cache が残っている状態、Nix 生成 image の tag が別 image を指す状態、cache は正しいが container が旧 image ID で動いている状態を成功にしない。doctor は state を作成、修復、pull、restart しない。

新規ホストでは OCI sync state が存在しないため、`dotfiles-sync-images` を実行してから doctor を実行する。同期中の standalone doctor は競合せず `blocked` を返す。rebuild transaction が image shared lock を precondition にする変更と、OCI container の `pull = "never"` への変更は次の決定に分ける。

schema v3 / v2 の rollback 対応は recovery generation が残る間だけ維持する。互換経路を forward へ広げない。

## 一次資料

- [OCI Image Manifest Specification: config digest と ImageID](https://github.com/opencontainers/image-spec/blob/v1.1.1/manifest.md#image-manifest-property-descriptions)
- [Docker Docs: content-addressable image store と image ID](https://docs.docker.com/reference/cli/docker/image/pull/)
- [NixOS OCI container module: `imageFile` の load](https://github.com/NixOS/nixpkgs/blob/bd0ff2d3eac24699c3664d5966b9ef36f388e2ca/nixos/modules/virtualisation/oci-containers.nix#L395-L410)
- [NixOS OCI container module: Docker container unit の生成](https://github.com/NixOS/nixpkgs/blob/bd0ff2d3eac24699c3664d5966b9ef36f388e2ca/nixos/modules/virtualisation/oci-containers.nix#L370-L523)
