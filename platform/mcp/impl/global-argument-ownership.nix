{
  lib,
  resolveUnitOwner,
}:

let
  isMcpUnit =
    owner:
    owner != null
    && (
      owner.id == "platform/mcp"
      || lib.hasPrefix "platform/mcp/" owner.id
      || lib.hasSuffix "/mcp" owner.id
    );

  scan =
    { units, definitions }:
    let
      inspectedDefinitions = map (
        definition:
        definition
        // {
          owner = resolveUnitOwner units definition.file;
        }
      ) definitions;
      inspectedArguments = lib.concatMap (
        definition:
        map (name: {
          inherit (definition) file owner;
          inherit name;
        }) (builtins.attrNames definition.value)
      ) inspectedDefinitions;
      coverage = {
        unitCount = builtins.length units;
        mcpUnitCount = builtins.length (builtins.filter isMcpUnit units);
        definitionCount = builtins.length inspectedDefinitions;
        argumentCount = builtins.length inspectedArguments;
        resolvedArgumentCount = builtins.length (
          builtins.filter (argument: argument.owner != null) inspectedArguments
        );
      };
      unresolvedDefinitionFiles = lib.unique (
        map (definition: definition.file) (
          builtins.filter (definition: definition.owner == null) inspectedDefinitions
        )
      );
      scanIntegrityViolations =
        lib.optional
          (coverage.unitCount == 0 || coverage.definitionCount == 0 || coverage.argumentCount == 0)
          "empty-scan:units=${toString coverage.unitCount},definitions=${toString coverage.definitionCount},arguments=${toString coverage.argumentCount}"
        ++ lib.optional (coverage.mcpUnitCount == 0) "no-mcp-units"
        ++ lib.optional (
          coverage.argumentCount > 0 && coverage.resolvedArgumentCount == 0
        ) "unresolved-scan:arguments=${toString coverage.argumentCount},resolved=0"
        ++ lib.optional (
          unresolvedDefinitionFiles != [ ]
        ) "unresolved-definitions=${lib.concatStringsSep " " unresolvedDefinitionFiles}";
      violations = map (argument: "${argument.file}:_module.args.${argument.name}") (
        builtins.filter (argument: isMcpUnit argument.owner) inspectedArguments
      );
      diagnostics =
        lib.optional (
          violations != [ ]
        ) "MCP unit defines global module arguments: ${lib.concatStringsSep " " violations}"
        ++ lib.optional (
          scanIntegrityViolations != [ ]
        ) "MCP global argument scan integrity failed: ${lib.concatStringsSep " " scanIntegrityViolations}";
    in
    {
      inherit
        coverage
        diagnostics
        scanIntegrityViolations
        unresolvedDefinitionFiles
        violations
        ;
      diagnosticText = lib.concatStringsSep "\n" diagnostics;
    };
in
{
  inherit scan;
}
