---
name: release-artifacts
description: Checks that a release artifact, its SBOM, its known-vulnerability scan, and its signature or provenance all refer to the same digest, using the project's own Syft, OSV-Scanner, and Cosign. Use when preparing or checking a release, container image, or distributable binary, or when asked whether an SBOM, scan result, signature, or attestation matches what will ship. Reports mismatches, tool versions, and unverified links. Not for source code or security review, signing or publishing without authorization, NuGet trusted-publishing setup, or installing tools outside the project.
---

# 配る成果物と証拠の対象を一致させる

利用者が受け取る成果物を digest で固定し、部品表、既知脆弱性の検査、署名、provenance がすべて同じ digest を対象にしていることを確かめる。
道具は対象 project の release 工程が固定したものを使い、署名と公開は許可された範囲だけで行う。

## 成果物を固定する

1. 何を配るか（container image、archive、package、binary、file の木）、版や tag、元の commit、作る release 工程（CI の workflow、devenv の task、script）を確かめる。
2. 成果物を digest で固定する。

| 成果物 | digest の取り方 |
|---|---|
| local の file | `sha256sum FILE` |
| registry の image | `docker buildx imagetools inspect REPO:TAG` で index の digest と platform ごとの manifest の digest を読み分ける |
| OCI layout の directory、archive | layout の `index.json` が指す manifest の digest |
| file の木（静的 asset の directory など） | release 工程が定める digest の一覧。受け取った木から同じ手順で計算し、隣に届いた控えを検証対象の代わりにしない |

tag は動くため、以降の手順はすべて `REPO@sha256:...` か file の hash で対象を指す。
multi-platform の image では、署名と SBOM が index と platform の manifest のどちらを対象にしたかを区別する。

## project の道具を確かめる

Syft、OSV-Scanner、Cosign は共通の PATH に無く、対象 project が devShell（`devenv.nix` の `packages`、flake の devShell）か、release の workflow で版を固定して供給する。
project の環境から版を読み、release 工程が使う版と照合する。入口は project の宣言で選ぶ。

| project の宣言 | 入口 |
|---|---|
| `devenv.nix` の `packages` | `devenv shell -- syft version`、`devenv shell -- osv-scanner --version`、`devenv shell -- cosign version` |
| `.envrc` の `use flake` と flake の devShell | `direnv exec CHECKOUT syft version` |

`direnv exec` は承認済みの `.envrc` が無ければ devShell を読み込まない。`.envrc` が無い、または未承認の flake は、devShell を評価して起動することが project を信頼する判断になるため、承認が必要な点を利用者へ示して待ち、`direnv allow` を代わりに実行しない。
release の workflow だけが版を固定し、手元で同じ版を起動できる project の入口が無い場合と、project が道具を供給していない場合は、不足として返す。
`nix profile install`、`go install`、`curl | sh`、package manager の global install で補わず、project への追加は利用者がその変更を許可した場合だけ project の宣言へ行う。
release 工程と違う版で作った証拠は、その release の証拠として扱わない。

## SBOM を作るか照合する

release 工程が SBOM を出す場合は、その file を受け取り、記述された対象が固定した digest と一致するかを読む。
自分で作る場合は、固定した対象を source に指定する。

```sh
syft scan registry:REPO@sha256:DIGEST -o cyclonedx-json=OUT/sbom.cdx.json
syft scan oci-dir:PATH/TO/LAYOUT -o spdx-json=OUT/sbom.spdx.json
syft scan file:PATH/TO/ARTIFACT -o cyclonedx-json=OUT/sbom.cdx.json
```

SBOM の対象の記述（syft-json の `.source`、CycloneDX の `.metadata.component`、SPDX の `documentDescribes` が指す package）から digest か file の hash を読み、固定した値と照合する。
source tree の `dir:` を走査した SBOM は build 前の依存の一覧であり、配る成果物の部品表として扱わない。
SBOM の file 名は OSV-Scanner が形式を判別できるよう `*.cdx.json` か `*.spdx.json` にする。

## 既知の脆弱性を照合する

同じ部品の一覧を検査するため、SBOM を入力にする。

```sh
osv-scanner scan source -L OUT/sbom.cdx.json --format json --output-file OUT/osv.json
```

終了 status は、0 が部品を見つけて既知の脆弱性に一致しなかった、1 が一致があった、128 が部品を一つも見つけられなかった、127 が一般の error を示す。
128 と 127 を「脆弱性なし」として扱わない。
online の照合は部品の名前と版を OSV.dev へ送るため、非公開の部品名を外部へ出せない project では、project が定める `--offline-vulnerabilities` の運用に従うか、未実施として返す。
照合した日時と、project の `osv-scanner.toml` による無視や上書きを、その理由と一緒に記録する。
無視の追加は project の owner の判断であり、検査を通すために足さない。
一致した脆弱性の到達可能性や影響の判断が求められた場合は `security-review` へ渡し、攻撃を試して確かめない。

## 署名と provenance を確かめる

検証は読み取り専用で、いつでも行える。
署名の方式は project ごとに違うため、一つの方式を既定にしない。

1. release 工程から、署名の方式（鍵ペアか keyless か）、transparency log への記録の有無、attestation の種類と subject、検証の入口を読む。
   読む先は CI の workflow、devenv の task と script、provenance の文書、project が採用する規範（architecture-standard では `tools/build/cosign.md`）である。
2. project が受け取る側の検証入口（devenv の検証 task など）を持つ場合は、それを固定した成果物へ実行し、終了 status と attestation ごとの結果を記録する。
   受け取りと配置の切替を一緒に行う入口は、検証の代わりに実行しない。
3. 専用の検証入口が無い場合や個別の照合を依頼された場合は、読んだ方式に合わせて Cosign を直接使う。

| 方式 | 検証の例 | 信頼の根拠 |
|---|---|---|
| 鍵ペアで、transparency log へ送らない | `cosign verify-blob-attestation --key PUB --insecure-ignore-tlog --type TYPE --bundle ATTESTATION BLOB`、image では `cosign verify-attestation --key PUB --insecure-ignore-tlog --type TYPE REPO@sha256:DIGEST` | 検証する側が保持する署名者の公開鍵。成果物の隣に届いた鍵は使わない |
| keyless（OIDC の証明書と公開の transparency log） | `cosign verify --certificate-identity IDENTITY --certificate-oidc-issuer ISSUER REPO@sha256:DIGEST`、`cosign verify-attestation --type TYPE --certificate-identity IDENTITY --certificate-oidc-issuer ISSUER REPO@sha256:DIGEST`、`cosign verify-blob --bundle ARTIFACT.sigstore.json --certificate-identity IDENTITY --certificate-oidc-issuer ISSUER ARTIFACT` | release workflow から確かめた具体的な identity と issuer。`--certificate-identity-regexp '.*'` のように誰の署名でも通る指定にしない |

`BLOB` は attestation の subject が覆う対象であり、file の木では release 工程が受け取った木から計算した digest の一覧になる。
`--check-claims` は既定で subject の digest を照合するため、無効にしない。
provenance は、記録された subject の digest、build の source の repository と commit、builder、build type が、固定した成果物と release 工程に一致するかを読む。

project の release 署名を作る場合は、その工程の署名入口を使う。ローカルの署名を求められた場合は、指定された方式と出力先で Cosign 等を使い、release 済みとは扱わない。
書き込む先が外部 registry または公開の transparency log なら、署名する digest、鍵か identity、書き込み先、公開の影響を示して実行直前に明示の許可を得る。
秘密鍵、`COSIGN_PASSWORD`、OIDC の token を引数、file、出力に書かない。

## 公開を分ける

registry への push、release の作成や asset の upload、package の publish は、このSkillで行わない。
GitHub の書込みは `github-operations` が account と対象を確かめて行い、NuGet の trusted publishing の設定は `nuget-trusted-publishing` が担う。

## 結果を返す

成果物の digest を軸に、SBOM の対象、脆弱性の検査の入力、署名と attestation と provenance の subject を一行ずつ対応させ、一致、不一致、未確認を示す。
使った道具の版と供給元、署名の方式と信頼の根拠（公開鍵の所在、または identity と issuer）、使った検証入口、照合した日時、出力 file の所在、無視した項目を添える。
検出された脆弱性は既知の一覧との一致であり、悪用可能性を確かめた所見とは書かない。
作れなかった証拠、許可されなかった署名、project が供給していない道具は、理由と一緒に未実施として残す。
