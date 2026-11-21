/**
  lazy stdio front が child を起こさずに返す discovery seed の構築
  capture: 固定済みの local executable を network の無い build sandbox で起動し、既知の protocol 版ごとの
    initialize と標準 list 応答を記録する。executable の文字列 context により実体の変更で作り直される
  committed: remote endpoint から公開 proxy 経由で一度だけ取得し、repository に置いた seed を同じ規則と
    利用者・一時・store path を含まない公開性の規則で検査して store へ置く
  戻り値: どちらも target の discoverySeed に渡す seed file の store path。derivation への依存を文字列の context に持つ
*/
{
  lib,
  python3,
  runCommand,
}:

let
  helper = "${lib.getExe python3} -I ${./discovery-seed.py}";
in
{
  capture =
    { name, executable }:
    "${runCommand "mcp-discovery-seed-${name}.json" { } ''
      ${helper} capture --output "$out" ${lib.escapeShellArg executable}
    ''}";

  committed =
    { name, seed }:
    "${runCommand "mcp-discovery-seed-${name}.json" { } ''
      ${helper} check --public ${seed}
      cp ${seed} "$out"
    ''}";
}
