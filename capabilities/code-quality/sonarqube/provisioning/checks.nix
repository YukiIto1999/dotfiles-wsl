{
  configuration = [
    (
      {
        pkgs,
        lib,
        hostConfig,
        mkProbeSystem,
        normalMachineModule,
        ...
      }:
      let
        lifecycle = hostConfig.dotfiles.capabilities.code-quality.sonarqube.lifecycle;
        backend = hostConfig.dotfiles.platform.containers.services.sonarqube;
        services = hostConfig.systemd.services;
        frontName = hostConfig.dotfiles.platform.mcp.fronts.sonarqube.service;
        frontUnit = "${frontName}.service";
        inherit (hostConfig.dotfiles.platform.containers) tryRestartUnit;
        serviceOf = unit: services.${lib.removeSuffix ".service" unit};
        target = hostConfig.systemd.targets.${lib.removeSuffix ".target" lifecycle.startUnit};
        provision = serviceOf "sonarqube-provision.service";
        stopUnits = [
          lifecycle.startUnit
          frontUnit
          "sonarqube-provision.service"
        ]
        ++ backend.units;

        rotations = {
          "secrets/sonarqube/admin_password" =
            hostConfig.sops.secrets."sonarqube/admin_password".restartUnits;
          "secrets/sonarqube/token" = hostConfig.sops.secrets."sonarqube/token".restartUnits;
          "templates/sonarqube.properties" = hostConfig.sops.templates."sonarqube.properties".restartUnits;
          "templates/sonarqube-db.env" = hostConfig.sops.templates."sonarqube-db.env".restartUnits;
          "templates/sonarqube-db-password" = hostConfig.sops.templates."sonarqube-db-password".restartUnits;
        };
        expectedRotations = {
          "secrets/sonarqube/admin_password" = [ (tryRestartUnit "sonarqube-provision.service") ];
          "secrets/sonarqube/token" = [ (tryRestartUnit frontUnit) ];
          "templates/sonarqube.properties" = [ (tryRestartUnit "docker-sonarqube.service") ];
          "templates/sonarqube-db.env" = [ (tryRestartUnit "docker-sonarqube-db.service") ];
          "templates/sonarqube-db-password" = [ (tryRestartUnit "docker-sonarqube-db.service") ];
        };

        # 旧来の常時起動を一つずつ戻した構成。各経路を module の assertion が拒否すること
        wakingConfig =
          (mkProbeSystem [
            normalMachineModule
            (
              { lib, ... }:
              {
                sops.templates."sonarqube.properties".restartUnits = lib.mkForce [ "docker-sonarqube.service" ];
                systemd.services.sonarqube-provision.wants = [ "docker-sonarqube.service" ];
                systemd.timers.sonarqube-provision = {
                  wantedBy = [ "timers.target" ];
                  timerConfig.OnBootSec = "2min";
                };
                systemd.services.${frontName}.wantedBy = [ "multi-user.target" ];
              }
            )
          ]).config;
        failedAssertions = map (assertion: assertion.message) (
          builtins.filter (assertion: !assertion.assertion) wakingConfig.assertions
        );
        rejects = prefix: lib.any (message: lib.hasPrefix prefix message) failedAssertions;

        fakeSystemctl = pkgs.writeShellApplication {
          name = "systemctl";
          text = ''
            case $1 in
              show)
                [[ $2 == --property=ActiveState && $3 == --value && $4 == -- && $# -eq 5 ]] || exit 64
                [[ ''${FAKE_SHOW_STATUS:-0} == 0 ]] || exit "$FAKE_SHOW_STATUS"
                if [[ -e $FAKE_STOP_LOG ]]; then
                  if [[ $5 == docker-sonarqube.service ]]; then
                    printf '%s\n' "''${FAKE_POST_STOP_STATE:-inactive}"
                  else
                    printf 'inactive\n'
                  fi
                else
                  printf '%s\n' "$FAKE_STATE"
                fi
                ;;
              stop) printf '%s\n' "$*" >>"$FAKE_STOP_LOG" ;;
              *) exit 64 ;;
            esac
          '';
        };
        fakeCurl = pkgs.writeShellApplication {
          name = "curl";
          text = ''
            printf '%s\n' "$*" >>"$FAKE_CURL_LOG"
            url=''${*: -1}
            case $url in
              */api/system/status)
                [[ $FAKE_STATUS != unreachable ]] || exit 7
                printf '{"status":"%s"}\n' "$FAKE_STATUS"
                ;;
              */api/ce/activity_status)
                # 認証情報は stdin の config だけで受け、argv に現れないこと
                cat >>"$FAKE_CURL_CONFIG"
                [[ ''${FAKE_ACTIVITY_STATUS:-0} == 0 ]] || exit "$FAKE_ACTIVITY_STATUS"
                printf '%s\n' "$FAKE_ACTIVITY"
                ;;
              *) exit 64 ;;
            esac
          '';
        };
        stopScript = pkgs.writeText "stop-backend.sh" (
          builtins.replaceStrings
            [
              "@serverUnit@"
              "@stopUnits@"
            ]
            [
              (lib.escapeShellArg "docker-sonarqube.service")
              (lib.escapeShellArgs stopUnits)
            ]
            (builtins.readFile ./impl/stop-backend.sh)
        );
      in
      {
        sonarqube-manual-lifecycle-contract =
          assert lib.assertMsg (backend.activation == "manual") "SonarQube must use manual activation";
          assert lib.assertMsg (lib.all (
            unit: (serviceOf unit).wantedBy == [ ] && !(serviceOf unit).restartIfChanged
          ) backend.units) "SonarQube containers must not start at boot nor restart on switch";
          assert lib.assertMsg (lib.all (
            image: !hostConfig.virtualisation.oci-containers.containers.${image.container}.autoStart
          ) (builtins.attrValues backend.images)) "SonarQube OCI containers must not auto-start";
          assert lib.assertMsg (
            target.wantedBy == [ ]
            && target.requiredBy == [ ]
            &&
              lib.sort builtins.lessThan target.requires == lib.sort builtins.lessThan [
                "docker-sonarqube.service"
                "sonarqube-provision.service"
                frontUnit
              ]
          ) "the SonarQube start target must require the server, provisioning and front without a boot want";
          assert lib.assertMsg (
            provision.wants == [ ]
            && provision.requires == [ ]
            && provision.requisite == [ "docker-sonarqube.service" ]
            && provision.partOf == [ "docker-sonarqube.service" ]
            && provision.wantedBy == [ ]
            && provision.serviceConfig.RemainAfterExit
            && !(hostConfig.systemd.timers ? sonarqube-provision)
          ) "SonarQube provisioning must follow the server start and restart without pulling it";
          assert lib.assertMsg (lib.all (
            unit: lib.elem "sonarqube-start-guard.service" (serviceOf unit).requires
          ) backend.units) "SonarQube containers must refuse starts during the guarded stop";
          assert lib.assertMsg (
            (serviceOf lifecycle.stopUnit).wantedBy == [ ]
            && (serviceOf lifecycle.stopUnit).after == [ ]
            && (serviceOf lifecycle.stopUnit).requires == [ ]
          ) "the SonarQube stop entry must not be ordered against the units it stops";
          assert lib.assertMsg (
            rotations == expectedRotations
          ) "SonarQube secret rotation must restart only already active units: ${builtins.toJSON rotations}";
          assert lib.assertMsg
            (
              rejects "secret restartUnits must reach manually activated units"
              && rejects "timers must not start manually activated container units"
              && rejects "manually activated container units and their dependents must not be wanted"
            )
            "a wake-up path for the stopped SonarQube backend escaped the assertions: ${builtins.toJSON failedAssertions}";
          pkgs.runCommandLocal "check-sonarqube-manual-lifecycle-contract" { } "touch $out";

        # 拒否と停止の判定は systemd、HTTP、lock の答えで決まるため境界を差し替えて deploy する script を実行
        sonarqube-guarded-stop-behavior =
          pkgs.runCommandLocal "check-sonarqube-guarded-stop-behavior"
            {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.coreutils
                pkgs.gnugrep
                pkgs.jq
                pkgs.util-linux
              ];
            }
            ''
              set -euo pipefail

              fakes=$PWD/fakes
              mkdir "$fakes"
              ln -s ${lib.getExe fakeSystemctl} "$fakes/systemctl"
              ln -s ${lib.getExe fakeCurl} "$fakes/curl"
              export PATH=$fakes:$PATH
              export FAKE_STOP_LOG=$PWD/stop.log FAKE_CURL_LOG=$PWD/curl.log FAKE_CURL_CONFIG=$PWD/curl.config
              export SONARQUBE_URL=http://127.0.0.1:9000
              export SONARQUBE_ADMIN_PASSWORD_FILE=$PWD/admin SONARQUBE_LIFECYCLE_LOCK=$PWD/scan.lock
              printf 'fixture-admin-secret' > admin
              : > scan.lock
              expected_stop=${lib.escapeShellArg "stop -- ${lib.concatStringsSep " " stopUnits}"}

              run() {
                rm -f stop.log
                set +e
                bash -euo pipefail ${stopScript} > out 2> err
                status=$?
                set -e
              }
              stops() {
                run
                [ "$status" -eq 0 ] || { cat err >&2; echo "stop was refused: $1" >&2; exit 1; }
                grep -Fxq -- "$expected_stop" stop.log || { echo "units were not stopped: $1" >&2; exit 1; }
              }
              refuses() {
                run
                [ "$status" -eq 1 ] || { echo "stop was not refused: $1" >&2; exit 1; }
                [ ! -e stop.log ] || { echo "a refused stop still stopped units: $1" >&2; exit 1; }
                grep -Fq -- "Refusing to stop SonarQube: $2" err || { cat err >&2; exit 1; }
              }

              FAKE_STATE=inactive stops "inactive server"
              FAKE_STATE=failed stops "failed server"
              [ ! -e curl.log ] || { echo "a stopped server was probed over HTTP" >&2; exit 1; }
              FAKE_STATE=activating refuses "activating server" "docker-sonarqube.service is activating"
              FAKE_STATE=deactivating refuses "deactivating server" "docker-sonarqube.service is deactivating"
              FAKE_STATE="" FAKE_SHOW_STATUS=1 refuses "unobservable server" "docker-sonarqube.service is unobservable"

              export FAKE_STATE=active
              FAKE_STATUS=unreachable refuses "silent API" "$SONARQUBE_URL/api/system/status did not answer"
              FAKE_STATUS=STARTING refuses "starting API" "server status is STARTING"
              FAKE_STATUS=DB_MIGRATION_RUNNING refuses "migrating API" "server status is DB_MIGRATION_RUNNING"
              FAKE_STATUS=DOWN stops "API without Compute Engine"

              export FAKE_STATUS=UP
              FAKE_ACTIVITY='{"pending":0,"inProgress":0,"failing":3}' stops "idle Compute Engine"
              FAKE_ACTIVITY='{"pending":0,"inProgress":0}' FAKE_POST_STOP_STATE=failed run
              [ "$status" -eq 1 ] || { echo 'stop succeeded with a failed container unit' >&2; exit 1; }
              grep -Fxq -- "$expected_stop" stop.log
              grep -Fq 'docker-sonarqube.service is failed' err
              FAKE_ACTIVITY='{"pending":2,"inProgress":0}' refuses "pending task" "2 pending and 0 in-progress"
              FAKE_ACTIVITY='{"pending":0,"inProgress":1}' refuses "running task" "0 pending and 1 in-progress"
              FAKE_ACTIVITY='{"pending":1e0,"inProgress":0}' refuses "exponent count" "1 pending and 0 in-progress"
              for malformed in '{"pending":-1,"inProgress":1}' '{"pending":0.5,"inProgress":0}' \
                '{"pending":"0","inProgress":0}' '{"inProgress":0}' 'not json'; do
                FAKE_ACTIVITY=$malformed refuses "malformed $malformed" "Compute Engine activity response has no pending and inProgress counts"
              done
              FAKE_ACTIVITY_STATUS=22 FAKE_ACTIVITY='{}' refuses "rejected credential" "could not read Compute Engine activity"
              if grep -Fq fixture-admin-secret curl.log; then
                echo "the admin password reached curl argv" >&2
                exit 1
              fi
              grep -Fq 'Authorization: Basic' curl.config

              FAKE_ACTIVITY='{"pending":0,"inProgress":0}'
              export FAKE_ACTIVITY
              exec 8<scan.lock
              flock --shared 8
              refuses "running wrapper scan" "a dotfiles-sonarqube-scan run holds the analysis lock"
              flock --unlock 8
              stops "released scan lock"

              if bash ${stopScript} --unknown > /dev/null 2>&1; then
                echo "an unknown argument was accepted" >&2
                exit 1
              fi
              bash ${stopScript} --help | grep -Fq "sudo systemctl start ${lifecycle.stopUnit}"

              touch $out
            '';
      }
    )
  ];
}
