{
  helpers,
  lib,
  pkgs,
  hostConfig,
  ...
}:

let
  expectedUrl = "http://127.0.0.1:9000";
  expectedPasswordFile = "/run/secrets/sonarqube/admin_password";
  expectedPort = 8778;
  expectedWaitUnits = [
    "docker-sonarqube.service"
    "docker-sonarqube-db.service"
  ];

  mkMcpServer = pkgs.callPackage ../package/mk-server.nix { };
  mkNpmMcp = pkgs.callPackage ../package/mk-npm.nix { };
  frontPackage = pkgs.callPackage ./package.nix {
    inherit mkMcpServer mkNpmMcp;
    sonarqubeUrl = expectedUrl;
    username = "admin";
    passwordFile = expectedPasswordFile;
  };
  front = hostConfig.dotfiles.mcp.fronts.sonarqube;
  target = hostConfig.dotfiles.mcp.targets.sonarqube;
  execStart = hostConfig.systemd.services.${front.service}.serviceConfig.ExecStart;
  execTokens = helpers.execTokens.tokensOf execStart;

  isolationBackendPackage =
    pkgs.runCommandLocal "sonarqube-isolation-backend"
      {
        meta.mainProgram = "sonarqube-mcp-server";
      }
      ''
        mkdir -p "$out/bin"
        touch "$out/bin/sonarqube-mcp-server"
      '';
  expectedNpmSpec = {
    pname = "sonarqube-mcp-server";
    version = "1.10.21";
    hash = "sha256-bJXCkWBmvP08lG/9X96dRIGkp+sO4bvu79aldutiT0o=";
    lockFile = ./package/package-lock.json;
    npmDepsHash = "sha256-sBW2ckDRuwXTiDsG6vhT3DjWtekhzmtupJ/m8niSlb4=";
  };

  mkIsolationCase =
    {
      passwordFile,
      sopsStub,
    }:
    let
      isolationFrontPackageFor =
        spec:
        let
          observedPasswordFile = builtins.head spec.requireNonEmpty;
          credentialTag = builtins.substring 0 12 (builtins.hashString "sha256" observedPasswordFile);
        in
        pkgs.runCommandLocal "sonarqube-isolation-front-${credentialTag}"
          {
            meta.mainProgram = "sonarqube-isolation-front-${credentialTag}";
          }
          ''
            mkdir -p "$out/bin"
            touch "$out/bin/sonarqube-isolation-front-${credentialTag}"
          '';
      expectedMcpSpec = {
        name = "sonarqube-mcp";
        env = {
          SONARQUBE_URL = expectedUrl;
          SONARQUBE_USERNAME = "admin";
          SONARQUBE_PASSWORD = "$(<${passwordFile})";
        };
        requireNonEmpty = [ passwordFile ];
        command = "${isolationBackendPackage}/bin/sonarqube-mcp-server";
      };
      isolationPkgs = pkgs // {
        callPackage =
          path: args:
          if path == ../package/mk-npm.nix then
            spec:
            assert builtins.toJSON spec == builtins.toJSON expectedNpmSpec;
            isolationBackendPackage
          else if path == ../package/mk-server.nix then
            spec:
            assert builtins.toJSON spec == builtins.toJSON expectedMcpSpec;
            isolationFrontPackageFor spec
          else if path == ../package/serve-over-proxy.nix then
            executable: "proxy:${executable}"
          else
            pkgs.callPackage path args;
      };
      evaluation = lib.evalModules {
        specialArgs.pkgs = isolationPkgs;
        modules = [
          ./module.nix
          (
            { lib, ... }:
            {
              options = {
                dotfiles.containers = {
                  services.sonarqube = lib.mkOption {
                    readOnly = true;
                    type = lib.types.submodule {
                      options = {
                        endpoints.http.url = lib.mkOption {
                          type = lib.types.str;
                          readOnly = true;
                        };
                        units = lib.mkOption {
                          type = lib.types.listOf lib.types.str;
                          readOnly = true;
                        };
                      };
                    };
                  };
                  sonarqube.credentials.adminPasswordFile = lib.mkOption {
                    type = lib.types.str;
                    readOnly = true;
                  };
                };
                dotfiles.mcp.targets = lib.mkOption {
                  default = { };
                  type = lib.types.attrsOf (
                    lib.types.submodule {
                      options = {
                        provider = lib.mkOption { type = lib.types.str; };
                        port = lib.mkOption { type = lib.types.port; };
                        serve = lib.mkOption { type = lib.types.str; };
                        needsNetwork = lib.mkOption {
                          type = lib.types.bool;
                          default = false;
                        };
                        waitUnits = lib.mkOption { type = lib.types.listOf lib.types.str; };
                        probe = lib.mkOption { type = lib.types.raw; };
                      };
                    }
                  );
                };
                sops = lib.mkOption { type = lib.types.raw; };
              };

              config = {
                dotfiles.containers = {
                  services.sonarqube = {
                    endpoints.http.url = expectedUrl;
                    units = [
                      "docker-sonarqube.service"
                      "docker-sonarqube-db.service"
                    ];
                  };
                  sonarqube.credentials.adminPasswordFile = passwordFile;
                };
                sops = sopsStub;
              };
            }
          )
        ];
      };
      isolatedTarget = evaluation.config.dotfiles.mcp.targets.sonarqube;
      expectedTarget = {
        provider = "sonarqube";
        port = expectedPort;
        serve = "proxy:${lib.getExe (isolationFrontPackageFor expectedMcpSpec)}";
        needsNetwork = false;
        waitUnits = expectedWaitUnits;
        probe = {
          tool = "system_status";
          args = { };
          timeout = 30;
        };
      };
    in
    {
      actual = builtins.toJSON {
        inherit (isolatedTarget)
          needsNetwork
          port
          probe
          provider
          serve
          waitUnits
          ;
      };
      expected = builtins.toJSON expectedTarget;
    };

  poisonCase = mkIsolationCase {
    passwordFile = expectedPasswordFile;
    sopsStub = throw "SonarQube front must not depend on SOPS";
  };
  sopsCanaryA = mkIsolationCase {
    passwordFile = expectedPasswordFile;
    sopsStub.secrets."sonarqube/admin_password".path = "/run/forbidden/sonarqube-canary-a";
  };
  sopsCanaryB = mkIsolationCase {
    passwordFile = expectedPasswordFile;
    sopsStub.secrets."sonarqube/admin_password".path = "/run/forbidden/sonarqube-canary-b";
  };
  credentialCanaryA = mkIsolationCase {
    passwordFile = "/run/typed/sonarqube-canary-a";
    sopsStub = throw "SonarQube front must not depend on SOPS";
  };
  credentialCanaryB = mkIsolationCase {
    passwordFile = "/run/typed/sonarqube-canary-b";
    sopsStub = throw "SonarQube front must not depend on SOPS";
  };
in
{
  sonarqube-front =
    assert target.port == expectedPort;
    assert target.waitUnits == expectedWaitUnits;
    assert lib.elem (lib.getExe frontPackage) execTokens;
    assert
      hostConfig.dotfiles.containers.sonarqube.credentials.adminPasswordFile == expectedPasswordFile;
    assert poisonCase.actual == poisonCase.expected;
    assert sopsCanaryA.actual == sopsCanaryA.expected;
    assert sopsCanaryB.actual == sopsCanaryB.expected;
    assert sopsCanaryA.actual == sopsCanaryB.actual;
    assert credentialCanaryA.actual == credentialCanaryA.expected;
    assert credentialCanaryB.actual == credentialCanaryB.expected;
    assert credentialCanaryA.actual != credentialCanaryB.actual;
    pkgs.runCommandLocal "check-sonarqube-front" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
      set -euo pipefail

      grep -Fqx 'export SONARQUBE_URL="${expectedUrl}"' ${lib.getExe frontPackage}
      grep -Fqx 'export SONARQUBE_USERNAME="admin"' ${lib.getExe frontPackage}
      grep -Fqx 'export SONARQUBE_PASSWORD="$(<${expectedPasswordFile})"' ${lib.getExe frontPackage}
      grep -q 'required file is empty' ${lib.getExe frontPackage}
      touch $out
    '';
}
