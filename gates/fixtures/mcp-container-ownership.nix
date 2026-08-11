let
  emptyDefinitions = {
    ociContainers = [ ];
    templates = [ ];
    services = [ ];
    secrets = [ ];
  };
  units = [
    {
      id = "mcp";
      path = "/fixture/mcp";
    }
    {
      id = "mcp/crawl4ai";
      path = "/fixture/mcp/crawl4ai";
    }
    {
      id = "containers/crawl4ai";
      path = "/fixture/containers/crawl4ai";
    }
    {
      id = "mcp/sonarqube";
      path = "/fixture/mcp/sonarqube";
    }
    {
      id = "containers/sonarqube";
      path = "/fixture/containers/sonarqube";
    }
  ];
in
{
  ownerCases = [
    {
      file = "mcp/crawl4ai/module.nix";
      expected = "mcp/crawl4ai";
    }
    {
      file = "mcp/crawl4ai/impl/review-backend.nix";
      expected = "mcp/crawl4ai";
    }
    {
      file = "mcp/crawl4aix/module.nix";
      expected = "mcp";
    }
    {
      file = "mcpish/crawl4ai/module.nix";
      expected = null;
    }
    {
      file = "mcp/module.nix";
      expected = "mcp";
    }
    {
      file = "mcp/sonarqube/module.nix";
      expected = "mcp/sonarqube";
    }
    {
      file = "README.md";
      expected = null;
    }
  ];

  scan = {
    inherit units;
    definitions = {
      ociContainers = [
        {
          file = "mcp/crawl4ai/module.nix";
          value.review = { };
        }
      ];
      templates = [
        {
          file = "mcp/crawl4ai/impl/review-template.nix";
          value."review.env" = { };
        }
      ];
      services = [
        {
          file = "mcp/crawl4ai/impl/review-backend.nix";
          value.crawl4ai = { };
        }
        {
          file = "mcp/crawl4ai/impl/other-backend.nix";
          value.searxng = { };
        }
        {
          file = "containers/crawl4ai/module.nix";
          value.crawl4ai = { };
        }
      ];
      secrets = [
        {
          file = "mcp/crawl4ai/impl/review-secret.nix";
          value."crawl4ai/api_token" = {
            mode = "0400";
            owner = "nixos";
            group = "users";
            restartUnits = [ "mcp-front-crawl4ai.service" ];
          };
        }
        {
          file = "mcp/crawl4ai/impl/restart-secret.nix";
          value."crawl4ai/api_token".restartUnits = [ "mcp-front-crawl4ai.service" ];
        }
        {
          file = "mcp/crawl4ai/impl/orphan-restart-secret.nix";
          value."crawl4ai/orphan".restartUnits = [ "mcp-front-crawl4ai.service" ];
        }
        {
          file = "mcp/crawl4ai/impl/other-secret.nix";
          value."searxng/secret_key" = { };
        }
        {
          file = "containers/crawl4ai/module.nix";
          value."crawl4ai/api_token" = { };
        }
      ];
    };
  };

  expectedScan = {
    coverage = {
      definitionCount = 10;
      mcpUnitCount = 3;
      resolvedDefinitionCount = 10;
      unitCount = 5;
    };
    diagnostics = [
      "MCP unit owns container backend declarations: mcp/crawl4ai/module.nix:virtualisation.oci-containers mcp/crawl4ai/impl/review-template.nix:sops.templates mcp/crawl4ai/impl/review-backend.nix:dotfiles.containers.services.crawl4ai mcp/crawl4ai/impl/review-secret.nix:sops.secrets.crawl4ai mcp/crawl4ai/impl/orphan-restart-secret.nix:sops.secrets.crawl4ai"
    ];
    diagnosticText = "MCP unit owns container backend declarations: mcp/crawl4ai/module.nix:virtualisation.oci-containers mcp/crawl4ai/impl/review-template.nix:sops.templates mcp/crawl4ai/impl/review-backend.nix:dotfiles.containers.services.crawl4ai mcp/crawl4ai/impl/review-secret.nix:sops.secrets.crawl4ai mcp/crawl4ai/impl/orphan-restart-secret.nix:sops.secrets.crawl4ai";
    scanIntegrityViolations = [ ];
    unresolvedMcpDefinitionFiles = [ ];
    violations = [
      "mcp/crawl4ai/module.nix:virtualisation.oci-containers"
      "mcp/crawl4ai/impl/review-template.nix:sops.templates"
      "mcp/crawl4ai/impl/review-backend.nix:dotfiles.containers.services.crawl4ai"
      "mcp/crawl4ai/impl/review-secret.nix:sops.secrets.crawl4ai"
      "mcp/crawl4ai/impl/orphan-restart-secret.nix:sops.secrets.crawl4ai"
    ];
  };

  emptyScan = {
    units = [ ];
    definitions = emptyDefinitions;
  };
  expectedEmptyScan = {
    coverage = {
      definitionCount = 0;
      mcpUnitCount = 0;
      resolvedDefinitionCount = 0;
      unitCount = 0;
    };
    diagnostics = [
      "MCP ownership scan integrity failed: empty-scan:units=0,definitions=0 no-mcp-units"
    ];
    diagnosticText = "MCP ownership scan integrity failed: empty-scan:units=0,definitions=0 no-mcp-units";
    scanIntegrityViolations = [
      "empty-scan:units=0,definitions=0"
      "no-mcp-units"
    ];
    unresolvedMcpDefinitionFiles = [ ];
    violations = [ ];
  };

  unresolvedScan = {
    units = [ (builtins.elemAt units 2) ];
    definitions = emptyDefinitions // {
      secrets = [
        {
          file = "mcp/orphan/impl/review-secret.nix";
          value."orphan/api_token" = { };
        }
      ];
    };
  };
  expectedUnresolvedScan = {
    coverage = {
      definitionCount = 1;
      mcpUnitCount = 0;
      resolvedDefinitionCount = 0;
      unitCount = 1;
    };
    diagnostics = [
      "MCP ownership scan integrity failed: no-mcp-units unresolved-scan:definitions=1,resolved=0 unresolved-mcp-definitions=mcp/orphan/impl/review-secret.nix"
    ];
    diagnosticText = "MCP ownership scan integrity failed: no-mcp-units unresolved-scan:definitions=1,resolved=0 unresolved-mcp-definitions=mcp/orphan/impl/review-secret.nix";
    scanIntegrityViolations = [
      "no-mcp-units"
      "unresolved-scan:definitions=1,resolved=0"
      "unresolved-mcp-definitions=mcp/orphan/impl/review-secret.nix"
    ];
    unresolvedMcpDefinitionFiles = [ "mcp/orphan/impl/review-secret.nix" ];
    violations = [ ];
  };

  combinedScan = {
    units = [
      (builtins.elemAt units 1)
      (builtins.elemAt units 2)
    ];
    definitions = emptyDefinitions // {
      ociContainers = [
        {
          file = "mcp/crawl4ai/module.nix";
          value.review = { };
        }
      ];
      secrets = [
        {
          file = "mcp/orphan/impl/review-secret.nix";
          value."orphan/api_token" = { };
        }
      ];
    };
  };
  expectedCombinedScan = {
    coverage = {
      definitionCount = 2;
      mcpUnitCount = 1;
      resolvedDefinitionCount = 1;
      unitCount = 2;
    };
    diagnostics = [
      "MCP unit owns container backend declarations: mcp/crawl4ai/module.nix:virtualisation.oci-containers"
      "MCP ownership scan integrity failed: unresolved-mcp-definitions=mcp/orphan/impl/review-secret.nix"
    ];
    diagnosticText = ''
      MCP unit owns container backend declarations: mcp/crawl4ai/module.nix:virtualisation.oci-containers
      MCP ownership scan integrity failed: unresolved-mcp-definitions=mcp/orphan/impl/review-secret.nix'';
    scanIntegrityViolations = [
      "unresolved-mcp-definitions=mcp/orphan/impl/review-secret.nix"
    ];
    unresolvedMcpDefinitionFiles = [ "mcp/orphan/impl/review-secret.nix" ];
    violations = [ "mcp/crawl4ai/module.nix:virtualisation.oci-containers" ];
  };
}
