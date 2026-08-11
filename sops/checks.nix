{
  pkgs,
  lib,
  self,
  hostConfig,
  hostOptions,
  helpers,
  ...
}:

let
  sopsFile = "${self}/sops/assets/secrets.yaml";
  sopsConfigFile = "${self}/sops/assets/.sops.yaml";
  templates = hostConfig.sops.templates;
  inHome = template: lib.hasPrefix hostConfig.dotfiles.host.homeDir template.path;
  wrongTemplatesFor =
    candidateTemplates:
    builtins.filter (
      template:
      inHome template && (template.mode != "0600" || template.owner != hostConfig.dotfiles.host.username)
    ) (builtins.attrValues candidateTemplates);
  templatePolicyIsValid =
    candidateTemplates: candidateTemplates != { } && wrongTemplatesFor candidateTemplates == [ ];
  normalTemplateEvaluation = builtins.tryEval (
    assert templatePolicyIsValid templates;
    true
  );
  emptyTemplateEvaluation = builtins.tryEval (
    assert templatePolicyIsValid { };
    true
  );

  secretObservationsFor =
    secrets:
    lib.mapAttrs' (
      id: secret:
      lib.nameValuePair "sops/${id}" {
        kind = "path-metadata";
        checkId = "secret/${id}";
        resourceKey = null;
        timeoutSeconds = 10;
        failureMessage = "${secret.path} metadata does not match the declared secret metadata";
        inherit (secret) path mode;
        owner = if secret.owner == null then "root" else secret.owner;
        group = if secret.group == null then "root" else secret.group;
      }
    ) secrets;
  selectSopsObservations = lib.filterAttrs (name: _: lib.hasPrefix "sops/" name);
  secrets = hostConfig.sops.secrets;
  sopsObservations = selectSopsObservations hostConfig.dotfiles.observations;
  expectedSopsObservations = secretObservationsFor secrets;
  sopsObservationKeys = builtins.attrNames expectedSopsObservations;
  sopsObservationDefinitions = builtins.filter (
    definition: lib.hasSuffix "/sops/module.nix" (toString definition.file)
  ) hostOptions.dotfiles.observations.definitionsWithLocations;
  sopsDefinitionKeys = lib.unique (
    lib.concatMap (definition: builtins.attrNames definition.value) sopsObservationDefinitions
  );
  uniqueNonNull =
    field: observations:
    let
      values = builtins.filter (value: value != null) (
        map (observation: observation.${field}) (builtins.attrValues observations)
      );
    in
    builtins.length values == builtins.length (lib.unique values);
  sopsContractMatches =
    candidateSecrets: candidateObservations:
    selectSopsObservations candidateObservations == secretObservationsFor candidateSecrets;

  secretIds = builtins.attrNames secrets;
  sampleSecretId = builtins.head secretIds;
  sampleObservationKey = "sops/${sampleSecretId}";
  missingObservationMutation = builtins.removeAttrs sopsObservations [ sampleObservationKey ];
  changedObservationMutation = sopsObservations // {
    ${sampleObservationKey} = sopsObservations.${sampleObservationKey} // {
      mode = "0440";
    };
  };
  staleObservationMutation = sopsObservations // {
    "sops/stale" = sopsObservations.${sampleObservationKey};
  };
  foreignObservationMutation = sopsObservations // {
    "host/independent-sops-fixture" = sopsObservations.${sampleObservationKey};
  };

  sopsFixtureOptions =
    { lib, ... }:
    {
      options = {
        sops = {
          defaultSopsFile = lib.mkOption { type = lib.types.path; };
          age = {
            keyFile = lib.mkOption { type = lib.types.str; };
            generateKey = lib.mkOption { type = lib.types.bool; };
          };
          secrets = lib.mkOption {
            type = lib.types.lazyAttrsOf (
              lib.types.submodule (
                { name, ... }:
                {
                  options = {
                    path = lib.mkOption {
                      type = lib.types.str;
                      default = "/run/secrets/${name}";
                    };
                    owner = lib.mkOption {
                      type = lib.types.nullOr lib.types.str;
                      default = null;
                    };
                    group = lib.mkOption {
                      type = lib.types.nullOr lib.types.str;
                      default = null;
                    };
                    mode = lib.mkOption {
                      type = lib.types.str;
                      default = "0400";
                    };
                    content = lib.mkOption {
                      type = lib.types.anything;
                      default = null;
                    };
                    sopsFile = lib.mkOption {
                      type = lib.types.str;
                      default = "/nix/store/fixture-secret-source";
                    };
                  };
                }
              )
            );
            default = { };
          };
        };
        systemd.tmpfiles.settings = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
        environment.systemPackages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [ ];
        };
      };
    };
  evalSopsConfig =
    candidateSecrets:
    (lib.evalModules {
      modules = [
        helpers.observationRegistryModule
        sopsFixtureOptions
        ./module.nix
        { sops.secrets = candidateSecrets; }
      ];
      specialArgs = { inherit pkgs; };
    }).config;
  fixtureSecrets."fixture/api_token" = {
    path = "/run/secrets/fixture/api_token";
    owner = "fixture";
    group = "fixture";
    mode = "0440";
    content = throw "secret content was evaluated while projecting metadata";
    sopsFile = "/nix/store/fixture-secret-source";
  };
  fixtureConfig = evalSopsConfig fixtureSecrets;
  emptyFixtureConfig = evalSopsConfig { };
  fixtureObservationJson = builtins.toJSON (
    selectSopsObservations fixtureConfig.dotfiles.observations
  );
  observationFields = [
    "checkId"
    "failureMessage"
    "group"
    "kind"
    "mode"
    "owner"
    "path"
    "resourceKey"
    "timeoutSeconds"
  ];
in
{
  # 鍵は root だけが読み、recipient は宣言と暗号文の両方で一致する
  sops-policy =
    assert toString hostConfig.sops.defaultSopsFile == sopsFile;
    assert hostConfig.sops.age.keyFile == "/var/lib/sops-nix/key.txt";
    assert !hostConfig.sops.age.generateKey;
    assert hostConfig.systemd.tmpfiles.settings."sops-key"."/var/lib/sops-nix/key.txt".z.mode == "0400";
    pkgs.runCommandLocal "check-sops-policy" { nativeBuildInputs = with pkgs; [ yq-go ]; } ''
      set -euo pipefail

      # 宣言した recipient と、暗号文が実際に持つ recipient が一致すること
      # anchor は explode しないと alias 名のまま出る
      yq -r 'explode(.) | .creation_rules[0].key_groups[0].age[]' ${sopsConfigFile} \
        | sort > declared
      yq -r '.sops.age[].recipient' ${sopsFile} | sort > actual
      diff -u declared actual

      # host 鍵と recovery 鍵の二つ。片方だけだと復旧手段が無い
      test "$(wc -l < declared)" -eq 2

      # 平文が残っていないこと。! 付きの command は set -e の対象外なので
      # 否定を条件式で書く
      if grep -qE '^[a-z_]+: [^E]' ${sopsFile}; then
        echo "secrets.yaml holds a plaintext value" >&2
        exit 1
      fi
      touch $out
    '';

  # secret file は user 所有で 0600。各 unit が mode を決めない
  sops-secret-file-mode =
    let
      wrong = wrongTemplatesFor templates;
    in
    assert normalTemplateEvaluation.success;
    assert !emptyTemplateEvaluation.success;
    assert templates != { };
    assert lib.assertMsg (wrong == [ ]) (
      "sops template does not use the shared user secret file policy: "
      + lib.concatStringsSep " " (map (t: t.path) wrong)
    );
    pkgs.runCommandLocal "check-sops-secret-file-mode" { } "touch $out";

  sops-runtime-observation-contract =
    assert secretIds != [ ];
    assert lib.assertMsg (
      sopsObservations == expectedSopsObservations
    ) "SOPS runtime observation registry is incomplete";
    assert lib.assertMsg (
      sopsDefinitionKeys == sopsObservationKeys
    ) "SOPS observations must be defined by the sops owner";
    assert lib.assertMsg (uniqueNonNull "checkId" sopsObservations)
      "SOPS runtime observation check IDs must be unique";
    assert lib.assertMsg (uniqueNonNull "resourceKey" sopsObservations)
      "SOPS runtime observation resource keys must be unique";
    assert lib.all (observation: observation.resourceKey == null) (
      builtins.attrValues sopsObservations
    );
    assert lib.all (observation: builtins.attrNames observation == observationFields) (
      builtins.attrValues sopsObservations
    );
    assert !(sopsContractMatches secrets missingObservationMutation);
    assert !(sopsContractMatches secrets changedObservationMutation);
    assert !(sopsContractMatches secrets staleObservationMutation);
    assert sopsContractMatches secrets foreignObservationMutation;
    assert sopsContractMatches fixtureConfig.sops.secrets fixtureConfig.dotfiles.observations;
    assert sopsContractMatches emptyFixtureConfig.sops.secrets emptyFixtureConfig.dotfiles.observations;
    assert !lib.hasInfix "fixture-secret-source" fixtureObservationJson;
    assert !lib.hasInfix "/nix/store/" fixtureObservationJson;
    pkgs.runCommandLocal "check-sops-runtime-observation-contract" { } "touch $out";
}
