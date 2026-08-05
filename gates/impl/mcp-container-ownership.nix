{ lib }:

let
  resolveUnitOwner =
    units: relativeFile:
    lib.foldl' (
      owner: unit:
      let
        ownsFile = relativeFile == unit.id || lib.hasPrefix "${unit.id}/" relativeFile;
        isCloserOwner = owner == null || builtins.stringLength unit.id > builtins.stringLength owner.id;
      in
      if ownsFile && isCloserOwner then unit else owner
    ) null units;

  isMcpUnit = owner: owner != null && (owner.id == "mcp" || lib.hasPrefix "mcp/" owner.id);
  targetOf = owner: lib.last (lib.splitString "/" owner.id);

  inspectDefinitions =
    units: definitions:
    lib.concatMap
      (
        group:
        map (
          definition:
          definition
          // {
            inherit (group) label mode;
            owner = resolveUnitOwner units definition.file;
          }
        ) group.definitions
      )
      [
        {
          label = "virtualisation.oci-containers";
          mode = "all";
          definitions = definitions.ociContainers;
        }
        {
          label = "sops.templates";
          mode = "all";
          definitions = definitions.templates;
        }
        {
          label = "dotfiles.containers.services";
          mode = "same-target";
          definitions = definitions.services;
        }
        {
          label = "sops.secrets";
          mode = "same-target-prefix";
          definitions = definitions.secrets;
        }
      ];

  violationsFor =
    inspected:
    lib.concatMap (
      definition:
      let
        inherit (definition) owner;
        target = if owner == null then null else targetOf owner;
        ownsTarget =
          if definition.mode == "all" then
            true
          else if definition.mode == "same-target" then
            builtins.hasAttr target definition.value
          else
            builtins.any (name: name == target || lib.hasPrefix "${target}/" name) (
              builtins.attrNames definition.value
            );
      in
      lib.optional (isMcpUnit owner && ownsTarget)
        "${definition.file}:${definition.label}${
          lib.optionalString (definition.mode != "all") ".${target}"
        }"
    ) inspected;

  scan =
    { units, definitions }:
    let
      inspected = inspectDefinitions units definitions;
      coverage = {
        definitionCount = builtins.length inspected;
        mcpUnitCount = builtins.length (builtins.filter isMcpUnit units);
        resolvedDefinitionCount = builtins.length (
          builtins.filter (definition: definition.owner != null) inspected
        );
        unitCount = builtins.length units;
      };
      unresolvedMcpDefinitionFiles = lib.unique (
        map (definition: definition.file) (
          builtins.filter (
            definition: definition.owner == null && lib.hasPrefix "mcp/" definition.file
          ) inspected
        )
      );
      scanIntegrityViolations =
        lib.optional (
          coverage.unitCount == 0 || coverage.definitionCount == 0
        ) "empty-scan:units=${toString coverage.unitCount},definitions=${toString coverage.definitionCount}"
        ++ lib.optional (coverage.mcpUnitCount == 0) "no-mcp-units"
        ++ lib.optional (
          coverage.definitionCount > 0 && coverage.resolvedDefinitionCount == 0
        ) "unresolved-scan:definitions=${toString coverage.definitionCount},resolved=0"
        ++ lib.optional (
          unresolvedMcpDefinitionFiles != [ ]
        ) "unresolved-mcp-definitions=${lib.concatStringsSep " " unresolvedMcpDefinitionFiles}";
      violations = violationsFor inspected;
      diagnostics =
        lib.optional (
          violations != [ ]
        ) "MCP unit owns container backend declarations: ${lib.concatStringsSep " " violations}"
        ++ lib.optional (
          scanIntegrityViolations != [ ]
        ) "MCP ownership scan integrity failed: ${lib.concatStringsSep " " scanIntegrityViolations}";
      diagnosticText = lib.concatStringsSep "\n" diagnostics;
    in
    {
      inherit
        coverage
        diagnosticText
        diagnostics
        scanIntegrityViolations
        unresolvedMcpDefinitionFiles
        violations
        ;
    };
in
{
  inherit resolveUnitOwner scan;
}
