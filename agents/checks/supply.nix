{
  configuration = [
    (
      {
        pkgs,
        lib,
        hostConfig,
        ...
      }:
      let
        mkCommand = import ../../platform/cli/impl/mk-command.nix {
          config = hostConfig;
          inherit lib pkgs;
        };
        mkSupply = import ../impl/supply.nix { inherit lib pkgs mkCommand; };

        fixtureShell =
          name: text:
          pkgs.writeShellApplication {
            inherit name text;
            runtimeInputs = [ pkgs.coreutils ];
          };
        fakeNix = fixtureShell "nix" (builtins.readFile ../fixtures/supply/fake-nix.sh);
        fakeNixEnv = fixtureShell "nix-env" (builtins.readFile ../fixtures/supply/fake-nix-env.sh);
        fakeMv = fixtureShell "mv" (builtins.readFile ../fixtures/supply/fake-mv.sh);
        fakeMktemp = fixtureShell "mktemp" (builtins.readFile ../fixtures/supply/fake-mktemp.sh);
        fixtureHook = fixtureShell "fixture-supply-hook" (
          builtins.readFile ../fixtures/supply/fixture-hook.sh
        );
        fixtureGc = fixtureShell "fixture-supply-gc" (builtins.readFile ../fixtures/supply/fixture-gc.sh);

        # fixture の store 実体は試験が実行時に作る。baseline は同じ名前規則の token で manifest へ渡す
        entryName =
          package: version:
          "${
            builtins.substring 0 32 (builtins.hashString "sha256" "${package}-${version}")
          }-${package}-${version}";
        fixtureClient = name: automatic: {
          inherit name automatic;
          binary = name;
          package = name;
          versionArgs = [ "--version" ];
          baseline = "@FIXTURE_STORE@/${entryName name "1"}";
        };
        manifest = [
          (fixtureClient "alpha" true)
          (fixtureClient "beta" false)
        ];
        losslessManifest = [
          (
            fixtureClient "gamma" false
            // {
              versionArgs = [
                "trailing\n"
                "\n"
                "embedded\nline"
                "  spaced  "
                "pipe|value"
              ];
            }
          )
        ];

        productionSource = builtins.readFile ../impl/agent-supply.sh;
        replaceOnce =
          from: to: text:
          assert lib.assertMsg (lib.hasInfix from text) "supply fixture anchor is missing: ${from}";
          builtins.replaceStrings [ from ] [ to ] text;
        # 本番の script を同じ本文のまま使い、実行時にしか決まらない store と HOME の位置、
        # 別 UID の観測だけを fixture 用に差し替える
        fixtureSource =
          {
            otherUid ? false,
            mismatchedHome ? false,
          }:
          builtins.toFile "agent-supply-fixture.sh" (
            lib.pipe productionSource (
              [
                (replaceOnce "store_dir=@nixStoreDir@" "store_dir=$FIXTURE_STORE")
                (replaceOnce "source_ref=@sourceRef@" "manifest=\${manifest//@FIXTURE_STORE@/$FIXTURE_STORE}\nsource_ref=@sourceRef@")
              ]
              ++ lib.optional (!mismatchedHome) (replaceOnce "home_dir=@homeDir@" "home_dir=$HOME")
              ++ lib.optional otherUid (replaceOnce "uid=$(id -u)" "uid=$(($(id -u) + 1))")
            )
          );
        fixtureSupply =
          {
            name,
            manifest,
            variant ? { },
          }:
          mkSupply {
            inherit name manifest;
            src = fixtureSource variant;
            sourceRef = "github:fixture/llm-agents";
            homeDir = "/declared-home-that-differs";
            profileRootRelative = ".local/share/dotfiles/agent-profiles";
            legacyRootRelative = ".local/share/dotfiles/agents";
            transactionHook = lib.getExe fixtureHook;
            nixPackage = null;
            leadingInputs = [
              fakeNix
              fakeNixEnv
              fakeMv
              fakeMktemp
            ];
          };
      in
      {
        agent-supply-behavior =
          pkgs.runCommandLocal "check-agent-supply-behavior"
            {
              nativeBuildInputs = with pkgs; [
                bash
                coreutils
                findutils
                gnugrep
                jq
                util-linux
              ];
              SUPPLY = lib.getExe (fixtureSupply {
                name = "fixture-agent-supply";
                inherit manifest;
              });
              SUPPLY_OTHER_UID = lib.getExe (fixtureSupply {
                name = "fixture-agent-supply-other-uid";
                inherit manifest;
                variant.otherUid = true;
              });
              SUPPLY_HOME_MISMATCH = lib.getExe (fixtureSupply {
                name = "fixture-agent-supply-home-mismatch";
                inherit manifest;
                variant.mismatchedHome = true;
              });
              SUPPLY_LOSSLESS = lib.getExe (fixtureSupply {
                name = "fixture-agent-supply-lossless";
                manifest = losslessManifest;
              });
              FIXTURE_GC = lib.getExe fixtureGc;
              FIXTURE_RUNTIME_SHELL = pkgs.runtimeShell;
              FIXTURE_SIGNAL_ENV = ../fixtures/supply/signal-window.sh;
            }
            ''
              bash ${../fixtures/supply/behavior.sh}
              touch $out
            '';
      }
    )
  ];
}
