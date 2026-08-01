{
  config,
  pkgs,
  lib,
  substituteCommandVars,
  ...
}:

# searxng settings template の secret は modules/mcp/servers/searxng.nix
# github account 関連は accounts/module.nix

let
  cfg = config.my;
  userHome = cfg.homeDir;
  inherit (config.sops) placeholder;

  userTpl = path: content: {
    inherit path content;
    mode = "0600";
    owner = cfg.username;
    group = "users";
  };

  gitIdentity = vars: builtins.readFile (pkgs.replaceVars ../git/assets/identity.conf vars);
  sopsVerifier = pkgs.writeShellApplication {
    name = "dotfiles-sops-verifier";
    runtimeInputs = with pkgs; [
      coreutils
      sops
    ];
    text = substituteCommandVars {
      sopsRuntimePath = lib.escapeShellArg (
        lib.makeBinPath [
          pkgs.coreutils
          pkgs.sops
        ]
      );
    } (builtins.readFile ./impl/sops-verifier.sh);
  };

  mkSopsKeyctl =
    name: allowTestHooks:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = with pkgs; [
        age
        coreutils
        jq
        nix
        sops
        util-linux
      ];
      text = substituteCommandVars {
        inherit allowTestHooks;
        nixEnv = lib.escapeShellArg (lib.getExe' pkgs.nix "nix-env");
        sopsKeyDirectory = lib.escapeShellArg (builtins.dirOf config.sops.age.keyFile);
        sopsRuntimePath = lib.escapeShellArg (
          lib.makeBinPath [
            pkgs.age
            pkgs.coreutils
            pkgs.sops
          ]
        );
        sopsVerifier = lib.escapeShellArg (lib.getExe sopsVerifier);
        systemdRun = lib.escapeShellArg (lib.getExe' pkgs.systemd "systemd-run");
      } (builtins.readFile ./impl/sops-keyctl.sh);
    };

  sopsKeyctl = mkSopsKeyctl "dotfiles-sops-keyctl" "0";
  sopsKeyctlTest = mkSopsKeyctl "dotfiles-sops-keyctl-test" "1";
  sopsTestSudo = pkgs.writeShellApplication {
    name = "dotfiles-sops-test-sudo";
    text = ''
      case ''${1-} in
        -v)
          [[ $# -eq 1 ]]
          ;;
        --)
          shift
          exec "$@"
          ;;
        *)
          exit 2
          ;;
      esac
    '';
  };

  mkSopsEnroll =
    name: allowTestHooks: keyctl: sudoCommand:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = with pkgs; [
        age
        coreutils
        diffutils
        findutils
        git
        gnugrep
        jq
        sops
        util-linux
        yq
      ];
      text = substituteCommandVars {
        inherit allowTestHooks;
        atomicFileFunctions = builtins.readFile ../rebuild/impl/lib/atomic-file.sh;
        configuredDotfiles = lib.escapeShellArg cfg.dotfilesDir;
        operationLockFunctions = builtins.readFile ../rebuild/impl/lib/operation-lock.sh;
        sopsKeyctl = lib.escapeShellArg (lib.getExe keyctl);
        sopsRuntimePath = lib.escapeShellArg (
          lib.makeBinPath [
            pkgs.coreutils
            pkgs.sops
          ]
        );
        sudoCommand = lib.escapeShellArg sudoCommand;
      } (builtins.readFile ./impl/sops-enroll.sh);
    };

  sopsEnrollTest = mkSopsEnroll "dotfiles-sops-enroll-test" "1" sopsKeyctlTest (
    lib.getExe sopsTestSudo
  );
  sopsEnroll =
    (mkSopsEnroll "dotfiles-sops-enroll" "0" sopsKeyctl "${config.security.wrapperDir}/sudo")
    .overrideAttrs
      (old: {
        passthru = (old.passthru or { }) // {
          testPackage = sopsEnrollTest;
          testKeyctl = sopsKeyctlTest;
          productionKeyctl = sopsKeyctl;
          productionVerifier = sopsVerifier;
        };
      });
  sopsGeneration = import ./impl/generation-contract.nix { inherit config pkgs; };
in
{
  options.my.sops.enrollmentState = lib.mkOption {
    type = lib.types.enum [
      "migration"
      "enrolled"
    ];
    description = "SOPS host identity の移行状態。doctor はここから legacy home key の扱いを導く。";
  };

  # host/recovery 両 identity の復号実測と home key 削除後に enrolled へ切り替える
  config.my.sops.enrollmentState = "migration";

  config.sops.defaultSopsFile = ../secrets/secrets.yaml;
  config.sops.age.keyFile = "/var/lib/sops-nix/key.txt";
  config.sops.age.generateKey = false;

  config.systemd.tmpfiles.settings."sops-key" = {
    "/var/lib/sops-nix".d = {
      user = "root";
      group = "root";
      mode = "0700";
    };
    "/var/lib/sops-nix/key.txt".z = {
      user = "root";
      group = "root";
      mode = "0400";
    };
  };

  config.sops.secrets = {
    "identity/default/name" = { };
    "identity/default/email" = { };
  }
  // lib.optionalAttrs (cfg.workIdentity != null) {
    "identity/work/name" = { };
    "identity/work/email" = { };
  };

  config.sops.templates = {
    "git-identity" = userTpl "${userHome}/.config/git/identity.conf" (gitIdentity {
      userName = placeholder."identity/default/name";
      userEmail = placeholder."identity/default/email";
    });
  }
  // lib.optionalAttrs (cfg.workIdentity != null) {
    "git-work-identity" = userTpl "${userHome}/.config/git/work-identity.conf" (gitIdentity {
      userName = placeholder."identity/work/name";
      userEmail = placeholder."identity/work/email";
    });
  };

  config.my.commands.sopsEnroll = sopsEnroll;
  config.environment.etc."dotfiles/sops-generation.json".source = sopsGeneration.contract;

  config.my.contract.secrets = {
    generation = sopsGeneration.contract;
    inherit (sopsGeneration) reinstallSecrets;
  };
}
