{
  pkgs,
  lib,
  self,
  hostConfig,
  hostOptions,
  variantConfig,
  ...
}:

let
  artifacts = hostConfig.my.artifacts;
  artifactSourcesFor =
    format:
    map (artifact: artifact.source) (
      builtins.attrValues (lib.filterAttrs (_: artifact: artifact.format == format) artifacts)
    );
  asArgs = files: lib.concatMapStringsSep " " (f: "${f}") files;

  # id の第一 segment は宣言した unit の名前で決まる。形式の一覧を手で持つと
  # 宣言と写しの一致しか見えない
  unitOf =
    declaration:
    let
      segments = lib.splitString "/" (lib.removePrefix "${self}/" (toString declaration));
      dirs = lib.take (builtins.length segments - 1) segments;
    in
    if dirs == [ ] then "" else lib.last dirs;

  misowned = lib.concatMap (
    definition:
    let
      unit = unitOf definition.file;
    in
    builtins.filter (id: !(builtins.elem unit (lib.splitString "/" id))) (
      builtins.attrNames definition.value
    )
  ) hostOptions.my.artifacts.definitionsWithLocations;
in
{
  artifact-registry =
    assert lib.assertMsg (misowned == [ ]) (
      "artifact id does not name its declaring unit: " + lib.concatStringsSep " " misowned
    );
    assert builtins.attrNames variantConfig.my.artifacts == builtins.attrNames artifacts;
    assert variantConfig.my.accounts == hostConfig.my.accounts;
    assert
      variantConfig.sops.templates."gh-hosts.yml".content
      == hostConfig.sops.templates."gh-hosts.yml".content;
    assert
      hostConfig.my.accounts == [ ]
      ||
        hostConfig.sops.templates."gh-hosts.yml".content
        == builtins.readFile artifacts."accounts/gh-hosts".source;
    pkgs.runCommandLocal "check-artifact-registry" { } "touch $out";

  # 各 producer が実配備へ渡す immutable source を形式別に検査する
  config-syntax =
    pkgs.runCommandLocal "check-config-syntax"
      {
        nativeBuildInputs = [
          pkgs.jq
          pkgs.taplo
          pkgs.yq
        ];
      }
      ''
        for f in ${asArgs (artifactSourcesFor "json")}; do
          jq empty "$f"
        done
        for f in ${asArgs (artifactSourcesFor "toml")}; do
          taplo lint "$f"
        done
        for f in ${asArgs (artifactSourcesFor "yaml")}; do
          yq . "$f" > /dev/null
        done
        touch $out
      '';

}
