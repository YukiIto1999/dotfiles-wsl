{
  config,
  lib,
  ...
}:

let
  cfg = config.dotfiles;
  deployedArtifacts = lib.filterAttrs (_: artifact: artifact.deployedAt != null) cfg.managedArtifacts;
  artifactObservations = lib.mapAttrs' (
    id: artifact:
    lib.nameValuePair "artifacts/${id}" {
      kind = "deployed-path";
      checkId = "artifact/${id}";
      resourceKey = null;
      timeoutSeconds = 10;
      failureMessage = "${artifact.deployedAt} does not match ${toString artifact.source}";
      source = toString artifact.source;
      destination = artifact.deployedAt;
      acceptedDestinationKinds = [
        "regular-file"
        "symlink"
      ];
    }
  ) deployedArtifacts;
in
{
  options.dotfiles.managedArtifacts = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          format = lib.mkOption {
            type = lib.types.enum [
              "json"
              "toml"
              "yaml"
              "markdown"
              "text"
              "directory"
            ];
            description = "source の形式。構文検査と配備照合の方法を決める。";
          };
          deployedAt = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "配備先の絶対パス。非 null なら doctor が乖離を検査する。";
          };
          source = lib.mkOption {
            type = lib.types.path;
            description = "配備側と検査側が共有する immutable source。";
          };
        };
      }
    );
    default = { };
    internal = true;
    description = "実配備 producer が一度だけ生成する不変設定 artifact。配備方法は各 module が所有する。";
  };

  config.dotfiles.health.observations = artifactObservations;
}
