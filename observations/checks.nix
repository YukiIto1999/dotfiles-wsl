{
  pkgs,
  lib,
  self,
  hostOptions,
  ...
}:

let
  fixture = import ./fixtures/contract.nix { inherit pkgs; };
  optionalFields = [
    "checkId"
    "resourceKey"
  ];
  commandProjections = [
    {
      command = fixture.valid."host/numeric-command-threshold".command;
      expectedName = "fixture-numeric-command-threshold-command";
    }
    {
      command = fixture.valid."host/normalized-protocol".command;
      expectedName = "fixture-normalized-protocol-command";
    }
  ];

  definitionModule = file: registry: {
    _file = "${self}/${file}";
    dotfiles.observations = registry;
  };
  evalRegistryModules =
    modules:
    lib.evalModules {
      modules = [ ./module.nix ] ++ modules;
    };
  evalRegistry = registry: evalRegistryModules [ (definitionModule "host/module.nix" registry) ];
  forceableValue =
    value:
    if lib.isDerivation value then
      value.drvPath
    else if builtins.isAttrs value then
      lib.mapAttrs (_: forceableValue) value
    else if builtins.isList value then
      map forceableValue value
    else
      value;
  evaluationSucceeds =
    evaluation:
    let
      attempted = builtins.tryEval (
        builtins.deepSeq (forceableValue evaluation.config.dotfiles.observations) true
      );
    in
    attempted.success && attempted.value;

  rootOf = file: lib.head (lib.splitString "/" (lib.removePrefix "${self}/" (toString file)));
  repositoryDefinitions =
    definitions:
    builtins.filter (definition: lib.hasPrefix "${self}/" (toString definition.file)) definitions;
  misownedDefinitions =
    options:
    lib.concatMap (
      definition:
      builtins.filter (id: lib.head (lib.splitString "/" id) != rootOf definition.file) (
        builtins.attrNames definition.value
      )
    ) (repositoryDefinitions options.dotfiles.observations.definitionsWithLocations);

  validEvaluation = evalRegistry fixture.valid;
  replaceObservation = id: observation: fixture.valid // { ${id} = observation; };
  missingRequiredCases = lib.concatMap (
    id:
    let
      observation = fixture.valid.${id};
      requiredFields = builtins.filter (field: !builtins.elem field optionalFields) (
        builtins.attrNames observation
      );
    in
    map (field: {
      name = "missing:${id}:${field}";
      registry = replaceObservation id (builtins.removeAttrs observation [ field ]);
    }) requiredFields
  ) (builtins.attrNames fixture.valid);
  kinds = map (observation: observation.kind) (builtins.attrValues fixture.valid);
  kindReplacementCases = lib.concatMap (
    id:
    let
      observation = fixture.valid.${id};
    in
    map (kind: {
      name = "kind:${id}:${kind}";
      registry = replaceObservation id (observation // { inherit kind; });
    }) (builtins.filter (kind: kind != observation.kind) kinds)
  ) (builtins.attrNames fixture.valid);
  invalidCommandCases = lib.concatMap (
    name:
    let
      command = fixture.invalidCommands.${name};
    in
    [
      {
        name = "numeric-command:${name}";
        registry = replaceObservation "host/numeric-command-threshold" (
          fixture.valid."host/numeric-command-threshold" // { inherit command; }
        );
      }
      {
        name = "normalized-command:${name}";
        registry = replaceObservation "host/normalized-protocol" (
          fixture.valid."host/normalized-protocol" // { inherit command; }
        );
      }
    ]
  ) (builtins.attrNames fixture.invalidCommands);
  explicitInvalidCases = lib.mapAttrsToList (name: registry: {
    inherit name registry;
  }) fixture.invalid;
  invalidCases =
    explicitInvalidCases ++ missingRequiredCases ++ kindReplacementCases ++ invalidCommandCases;
  invalidResults = map (
    invalidCase: invalidCase // { succeeds = evaluationSucceeds (evalRegistry invalidCase.registry); }
  ) invalidCases;
  unexpectedValid = map (result: result.name) (
    builtins.filter (result: result.succeeds) invalidResults
  );
  optionalCommonEvaluation = evalRegistry (
    fixture.valid
    // {
      "host/roster" = builtins.removeAttrs fixture.valid."host/roster" [
        "checkId"
        "resourceKey"
      ];
    }
  );
  emptyNormalizedProtocolResourcesEvaluation = evalRegistry (
    fixture.valid
    // {
      "host/normalized-protocol" = fixture.valid."host/normalized-protocol" // {
        requiredResourceKeys = [ ];
      };
    }
  );
  nestedDefinitionModule = file: {
    _file = "${self}/${file}";
    dotfiles.observations."host/sample".failureMessage = "nested fixture failure";
  };
  ownerCorrectEvaluation = evalRegistryModules [ (nestedDefinitionModule "host/module.nix") ];
  ownerForeignEvaluation = evalRegistryModules [ (nestedDefinitionModule "mcp/module.nix") ];
  dynamicOwnerKeyEvaluation = evalRegistryModules [
    (definitionModule "sops/module.nix" {
      "sops/crawl4ai/api_token" = fixture.valid."host/roster";
      "sops/crawl4ai/api-token" = fixture.valid."host/roster";
      "sops/crawl4ai/api.token" = fixture.valid."host/roster";
    })
  ];
  invalidDynamicOwnerKeyEvaluations =
    map
      (
        id:
        evalRegistryModules [
          (definitionModule "sops/module.nix" { ${id} = fixture.valid."host/roster"; })
        ]
      )
      [
        "sops/"
        "sops/."
        "sops/.."
        "sops/_private"
        "sops/Uppercase"
        "sops/invalid@segment"
        "sops/empty//segment"
      ];
in
{
  observation-contract =
    assert builtins.length (builtins.attrNames fixture.valid) == 17;
    assert evaluationSucceeds validEvaluation;
    assert evaluationSucceeds (evalRegistry { });
    assert evaluationSucceeds optionalCommonEvaluation;
    assert evaluationSucceeds emptyNormalizedProtocolResourcesEvaluation;
    assert optionalCommonEvaluation.config.dotfiles.observations."host/roster".checkId == null;
    assert optionalCommonEvaluation.config.dotfiles.observations."host/roster".resourceKey == null;
    assert builtins.length missingRequiredCases == 112;
    assert builtins.length kindReplacementCases == 272;
    assert builtins.length invalidCommandCases == 18;
    assert lib.all (
      projection:
      projection.command.meta.mainProgram == projection.expectedName
      &&
        lib.getExe projection.command == "${lib.getBin projection.command}/bin/${projection.expectedName}"
    ) commandProjections;
    assert lib.assertMsg (unexpectedValid == [ ]) (
      "invalid observation contract evaluation succeeded: " + lib.concatStringsSep " " unexpectedValid
    );
    assert misownedDefinitions ownerCorrectEvaluation.options == [ ];
    assert misownedDefinitions ownerForeignEvaluation.options == [ "host/sample" ];
    assert evaluationSucceeds dynamicOwnerKeyEvaluation;
    assert lib.all (evaluation: !evaluationSucceeds evaluation) invalidDynamicOwnerKeyEvaluations;
    assert misownedDefinitions dynamicOwnerKeyEvaluation.options == [ ];
    assert lib.assertMsg (
      misownedDefinitions hostOptions == [ ]
    ) "observation registry key first segment must match its defining owner root";
    pkgs.runCommandLocal "check-observation-contract" { } "touch $out";
}
