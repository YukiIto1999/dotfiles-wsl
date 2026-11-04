{
  configuration = [
    (
      {
        lib,
        pkgs,
        hostConfig,
        ...
      }:
      let
        homeConfig = hostConfig.home-manager.users.${hostConfig.dotfiles.workstation.username};
        deployedHook = "${homeConfig.home.file.".omp/agent/hooks/pre".source}/project-memory.ts";
        deployedRuntime = hostConfig.dotfiles.capabilities.project-memory.runtime;
        hookUsing =
          memory:
          pkgs.runCommandLocal "omp-project-memory-hook.ts" { } ''
            substitute ${deployedHook} $out \
              --replace-fail ${lib.getExe deployedRuntime} ${memory}
          '';
        runtime = deployedRuntime.override { apiUrl = "http://127.0.0.1:18082"; };
        fakeMemory = pkgs.writeShellScript "fake-project-memory" ''
          set -euo pipefail
          payload=$(${pkgs.coreutils}/bin/cat)
          prompt=$(${pkgs.jq}/bin/jq -r .prompt <<<"$payload")
          session=$(${pkgs.jq}/bin/jq -r .session_id <<<"$payload")
          cwd=$(${pkgs.jq}/bin/jq -r .cwd <<<"$payload")
          printf '%s\t%s\t%s\t%s\n' "$$" "$session" "$cwd" "$prompt" >> "$FAKE_MEMORY_DIR/calls.log"
          number=$(${pkgs.coreutils}/bin/wc -l < "$FAKE_MEMORY_DIR/calls.log")
          case $prompt in
            fail:*)
              echo "backend unavailable" >&2
              exit 1
              ;;
            hang:*)
              ${pkgs.coreutils}/bin/sleep 300 &
              printf '%s\n' "$!" > "$FAKE_MEMORY_DIR/descendant.pid"
              wait
              ;;
            hold:*)
              while [ ! -e "$FAKE_MEMORY_DIR/release" ]; do
                ${pkgs.coreutils}/bin/sleep 0.05
              done
              ;;
          esac
          printf '<project_memory>\ncall %s session=%s cwd=%s prompt=%s\n</project_memory>\n' "$number" "$session" "$cwd" "$prompt"
        '';
      in
      {
        agent-omp-project-memory-hook =
          pkgs.runCommandLocal "check-agent-omp-project-memory-hook"
            {
              nativeBuildInputs = [
                pkgs.bun
                pkgs.git
              ];
              FAKE_MEMORY_HOOK = hookUsing fakeMemory;
              BACKEND_MEMORY_HOOK = hookUsing (lib.getExe runtime);
              MEMORY_BINARY = lib.getExe runtime;
            }
            ''
              export HOME=$PWD/home
              export FAKE_MEMORY_DIR=$PWD/memory
              mkdir -p "$HOME"
              cp ${./checks/project-memory.test.ts} project-memory.test.ts
              bun test ./project-memory.test.ts
              touch $out
            '';
      }
    )
  ];
}
