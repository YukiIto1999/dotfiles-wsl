{
  pkgs,
  lib,
  hostConfig,
  ...
}:

let
  agentConfig = hostConfig.dotfiles.agents;
  apm = agentConfig.packages.apm;
  atomicPublish = import ../impl/atomic-publish.nix { inherit pkgs; };
  atomicPublishExe = lib.getExe' atomicPublish "dotfiles-agent-atomic-publish";
  packageTreeFixtureRecord = {
    name = "codex";
    binary = "codex";
    versionArgs = [ "--version" ];
    install = {
      kind = "github-release";
      updateOwner = "dotfiles";
      layout = "package-tree";
      repo = "openai/codex";
      retainedReleases = 2;
      releaseByArch = {
        x86_64 = {
          asset = "codex-package-x86_64-unknown-linux-musl.tar.gz";
          entrypoint = "bin/codex";
        };
        aarch64 = {
          asset = "codex-package-aarch64-unknown-linux-musl.tar.gz";
          entrypoint = "bin/codex";
        };
      };
      requiredPaths = {
        "bin/codex" = {
          kind = "file";
          executable = true;
        };
        "codex-package.json" = {
          kind = "file";
          executable = false;
        };
        "bin/codex-code-mode-host" = {
          kind = "file";
          executable = true;
        };
        "codex-path/rg" = {
          kind = "file";
          executable = true;
        };
        "codex-resources/bwrap" = {
          kind = "file";
          executable = true;
        };
      };
    };
  };
  packageTreeFixtureManifest = builtins.toJSON [ packageTreeFixtureRecord ];
  missingArchFixtureManifest = builtins.toJSON [
    (
      packageTreeFixtureRecord
      // {
        install = packageTreeFixtureRecord.install // {
          releaseByArch = builtins.removeAttrs packageTreeFixtureRecord.install.releaseByArch [ "x86_64" ];
        };
      }
    )
  ];
  emptyAssetFixtureManifest = builtins.toJSON [
    (
      packageTreeFixtureRecord
      // {
        install = packageTreeFixtureRecord.install // {
          releaseByArch = packageTreeFixtureRecord.install.releaseByArch // {
            x86_64 = packageTreeFixtureRecord.install.releaseByArch.x86_64 // {
              asset = "";
            };
          };
        };
      }
    )
  ];
  emptyEntrypointFixtureManifest = builtins.toJSON [
    (
      packageTreeFixtureRecord
      // {
        install = packageTreeFixtureRecord.install // {
          releaseByArch = packageTreeFixtureRecord.install.releaseByArch // {
            x86_64 = packageTreeFixtureRecord.install.releaseByArch.x86_64 // {
              entrypoint = "";
            };
          };
        };
      }
    )
  ];
  retentionOneFixtureManifest = builtins.toJSON [
    (
      packageTreeFixtureRecord
      // {
        install = packageTreeFixtureRecord.install // {
          retainedReleases = 1;
        };
      }
    )
  ];
  retentionElevenFixtureManifest = builtins.toJSON [
    (
      packageTreeFixtureRecord
      // {
        install = packageTreeFixtureRecord.install // {
          retainedReleases = 11;
        };
      }
    )
  ];
  invalidClientDotFixtureManifest = builtins.toJSON [
    (packageTreeFixtureRecord // { name = "."; })
  ];
  invalidClientDotDotFixtureManifest = builtins.toJSON [
    (packageTreeFixtureRecord // { name = ".."; })
  ];
  invalidClientSlashFixtureManifest = builtins.toJSON [
    (packageTreeFixtureRecord // { name = "bad/name"; })
  ];
  invalidClientCharacterFixtureManifest = builtins.toJSON [
    (packageTreeFixtureRecord // { name = "bad name"; })
  ];
  singleBinaryFixtureManifest = builtins.toJSON [
    {
      name = "opencode";
      binary = "opencode";
      versionArgs = [ "--version" ];
      install = {
        kind = "github-release";
        updateOwner = "dotfiles";
        layout = "single-binary";
        repo = "anomalyco/opencode";
        retainedReleases = 2;
        releaseByArch = {
          x86_64 = {
            asset = "opencode-linux-x64.tar.gz";
            entrypoint = "opencode";
          };
          aarch64 = {
            asset = "opencode-linux-arm64.tar.gz";
            entrypoint = "opencode";
          };
        };
        requiredPaths = { };
      };
    }
  ];
  packageTreeFixtureCurl = pkgs.writeShellApplication {
    name = "curl";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.readFile ../fixtures/install-agents/fake-curl.sh;
  };
  packageTreeFixtureUname = pkgs.writeShellApplication {
    name = "uname";
    text = builtins.readFile ../fixtures/install-agents/fake-uname.sh;
  };
  packageTreeFixtureTar = pkgs.writeShellApplication {
    name = "tar";
    text = builtins.replaceStrings [ "@tarCommand@" ] [ (lib.getExe pkgs.gnutar) ] (
      builtins.readFile ../fixtures/install-agents/fake-tar.sh
    );
  };
  packageTreeTransactionHook = pkgs.writeShellApplication {
    name = "fixture-install-agents-transaction-hook";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.readFile ../fixtures/install-agents/fake-transaction-hook.sh;
  };
  atomicPublishHookSupport = import ./support/atomic-publish-hook.nix {
    inherit pkgs;
  };
  inherit (atomicPublishHookSupport) atomicPublishTestHook;
  atomicPublishFixture = pkgs.runCommandCC "fixture-dotfiles-agent-atomic-publish" { } ''
    mkdir -p "$out/bin"
    $CC -std=c11 -O2 -Wall -Wextra -Werror \
      '-DDOTFILES_ATOMIC_TEST_HOOK="${lib.getExe atomicPublishTestHook}"' \
      ${../impl/atomic-publish.c} \
      -o "$out/bin/dotfiles-agent-atomic-publish"
  '';
  atomicPublishFixtureExe = lib.getExe' atomicPublishFixture "dotfiles-agent-atomic-publish";
  fixtureProbeEnvironment = ''
    FIXTURE_ATOMIC_HOOK_EVENT="''${FIXTURE_ATOMIC_HOOK_EVENT-}" \
    FIXTURE_ATOMIC_HOOK_ACTION="''${FIXTURE_ATOMIC_HOOK_ACTION-}" \
    FIXTURE_ATOMIC_HOOK_SOURCE="''${FIXTURE_ATOMIC_HOOK_SOURCE-}" \
    FIXTURE_ATOMIC_HOOK_MARKER="''${FIXTURE_ATOMIC_HOOK_MARKER-}" \
    FIXTURE_ATOMIC_HOOK_SAVED="''${FIXTURE_ATOMIC_HOOK_SAVED-}" \
    FIXTURE_ATOMIC_HOOK_TARGET="''${FIXTURE_ATOMIC_HOOK_TARGET-}" \
    FIXTURE_ATOMIC_HOOK_ROOT="''${FIXTURE_ATOMIC_HOOK_ROOT-}" \
    FIXTURE_ATOMIC_HOOK_FAKE_EXECUTABLE="''${FIXTURE_ATOMIC_HOOK_FAKE_EXECUTABLE-}" \
  '';
  mkInstallerBehaviorFixture =
    name: manifest:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [
        atomicPublishFixture
        packageTreeFixtureCurl
        packageTreeFixtureUname
        packageTreeFixtureTar
      ]
      ++ (with pkgs; [
        bash
        coreutils
        diffutils
        findutils
        gawk
        gnutar
        gzip
        jq
        util-linux
      ]);
      text =
        builtins.replaceStrings
          [
            "@atomicPublishCommand@"
            "@installManifest@"
            "@probeEnvironment@"
            "@transactionHookCommand@"
            "@versionArgsDecoder@"
          ]
          [
            (lib.escapeShellArg atomicPublishFixtureExe)
            manifest
            fixtureProbeEnvironment
            (lib.escapeShellArg (lib.getExe packageTreeTransactionHook))
            (builtins.readFile ../impl/version-args.sh)
          ]
          (builtins.readFile ../impl/install-agents.sh);
    };
  packageTreeFixtureInstaller = mkInstallerBehaviorFixture "fixture-install-package-tree-agent" packageTreeFixtureManifest;
  missingArchFixtureInstaller = mkInstallerBehaviorFixture "fixture-install-missing-arch-agent" missingArchFixtureManifest;
  emptyAssetFixtureInstaller = mkInstallerBehaviorFixture "fixture-install-empty-asset-agent" emptyAssetFixtureManifest;
  emptyEntrypointFixtureInstaller = mkInstallerBehaviorFixture "fixture-install-empty-entrypoint-agent" emptyEntrypointFixtureManifest;
  retentionOneFixtureInstaller = mkInstallerBehaviorFixture "fixture-install-retention-one-agent" retentionOneFixtureManifest;
  retentionElevenFixtureInstaller = mkInstallerBehaviorFixture "fixture-install-retention-eleven-agent" retentionElevenFixtureManifest;
  invalidClientDotFixtureInstaller = mkInstallerBehaviorFixture "fixture-install-client-dot-agent" invalidClientDotFixtureManifest;
  invalidClientDotDotFixtureInstaller = mkInstallerBehaviorFixture "fixture-install-client-dot-dot-agent" invalidClientDotDotFixtureManifest;
  invalidClientSlashFixtureInstaller = mkInstallerBehaviorFixture "fixture-install-client-slash-agent" invalidClientSlashFixtureManifest;
  invalidClientCharacterFixtureInstaller = mkInstallerBehaviorFixture "fixture-install-client-character-agent" invalidClientCharacterFixtureManifest;
  singleBinaryFixtureInstaller = mkInstallerBehaviorFixture "fixture-install-single-binary-agent" singleBinaryFixtureManifest;
in
{
  agent-apm-binary-runs = pkgs.runCommandLocal "check-agent-apm-binary-runs" { } ''
    set -euo pipefail

    version=$(${lib.getExe apm} --version)
    case $version in
      "Agent Package Manager (APM) CLI version ${apm.version}"*) ;;
      *)
        echo "unexpected apm version banner: $version" >&2
        exit 1
        ;;
    esac
    touch $out
  '';

  agent-installer-behavior =
    pkgs.runCommandLocal "check-agent-installer-behavior"
      {
        nativeBuildInputs = with pkgs; [
          bash
          coreutils
          gnutar
          gzip
          jq
          python3
          util-linux
        ];
      }
      ''
        set -euo pipefail
        export INSTALL_AGENTS=${lib.getExe packageTreeFixtureInstaller}
        export INSTALL_AGENTS_MISSING_ARCH=${lib.getExe missingArchFixtureInstaller}
        export INSTALL_AGENTS_EMPTY_ASSET=${lib.getExe emptyAssetFixtureInstaller}
        export INSTALL_AGENTS_EMPTY_ENTRYPOINT=${lib.getExe emptyEntrypointFixtureInstaller}
        export INSTALL_AGENTS_RETENTION_ONE=${lib.getExe retentionOneFixtureInstaller}
        export INSTALL_AGENTS_RETENTION_ELEVEN=${lib.getExe retentionElevenFixtureInstaller}
        export INSTALL_AGENTS_CLIENT_DOT=${lib.getExe invalidClientDotFixtureInstaller}
        export INSTALL_AGENTS_CLIENT_DOT_DOT=${lib.getExe invalidClientDotDotFixtureInstaller}
        export INSTALL_AGENTS_CLIENT_SLASH=${lib.getExe invalidClientSlashFixtureInstaller}
        export INSTALL_AGENTS_CLIENT_CHARACTER=${lib.getExe invalidClientCharacterFixtureInstaller}
        export INSTALL_AGENTS_SINGLE_BINARY=${lib.getExe singleBinaryFixtureInstaller}
        export ATOMIC_PUBLISH=${atomicPublishFixtureExe}
        export ATOMIC_PUBLISH_PRODUCTION=${atomicPublishExe}
        export FIXTURE_SOURCES=${../fixtures/install-agents}
        export FIXTURE_RUNTIME_SHELL=${pkgs.runtimeShell}
        export PROBE_ELF=${lib.getExe pkgs.hello}
        for variable in EVENT ACTION SOURCE MARKER SAVED TARGET ROOT FAKE_EXECUTABLE; do
          grep -Fq "FIXTURE_ATOMIC_HOOK_$variable=" "$INSTALL_AGENTS"
        done
        grep -Fq 'O_CLOEXEC' ${../impl/atomic-publish.c}
        grep -Fq 'FD_CLOEXEC' ${../impl/atomic-publish.c}
        grep -Fq 'EXIT_USAGE = 2' ${../impl/atomic-publish.c}
        grep -Fq 'EXIT_DIRECTORY = 3' ${../impl/atomic-publish.c}
        grep -Fq 'EXIT_CONFLICT = 4' ${../impl/atomic-publish.c}
        grep -Fq 'EXIT_SYSCALL = 5' ${../impl/atomic-publish.c}
        grep -Fq 'EXIT_AMBIGUOUS = 6' ${../impl/atomic-publish.c}
        grep -Fq 'SYS_openat2' ${../impl/atomic-publish.c}
        grep -Fq 'RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS' ${../impl/atomic-publish.c}
        grep -Fq 'st_nlink' ${../impl/atomic-publish.c}
        grep -Fq '.atomic-quarantine' ${../impl/atomic-publish.c}
        grep -Fq 'RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS' ${../impl/atomic-publish.c}
        grep -Fq 'unsigned char random_bytes[16]' ${../impl/atomic-publish.c}
        grep -Fq 'not a security boundary against a malicious process' ${../impl/atomic-publish.c}
        awk '
          /target_after\.missing && same_identity\(&quarantine_after, &before\)/ {
            after_private_identity = 1
          }
          after_private_identity && /run_test_hook/ { exit 1 }
          after_private_identity && /unlinkat\(quarantine_directory/ {
            found_private_unlink = 1
            exit 0
          }
          END { if (!found_private_unlink) exit 1 }
        ' ${../impl/atomic-publish.c} || {
          echo "atomic helper inserts a hook before the verified private unlink" >&2
          exit 1
        }
        bash ${../fixtures/install-agents/atomic-security.sh}
        bash ${../fixtures/install-agents/behavior.sh}
        touch $out
      '';
}
