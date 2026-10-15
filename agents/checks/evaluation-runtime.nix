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
        agentConfig = hostConfig.dotfiles.agents;
        homeConfig = hostConfig.home-manager.users.${hostConfig.dotfiles.workstation.username};
        inherit (hostConfig.dotfiles.workstation) homeDir;
        descriptorPath = ".local/share/dotfiles-agent/evaluation-runtime.json";
        deployedDescriptor = homeConfig.home.file.${descriptorPath}.source;
        artifact = hostConfig.dotfiles.managedArtifacts."agents/evaluation-runtime";
        # 生成側と同じ式の再利用は検査が循環するため不可
        ompWrapper = "${agentConfig.lifecycle.wrapperDirectory}/${agentConfig.clients.omp.binary}";
        expected = {
          version = 1;
          omp = {
            executable = ompWrapper;
            arguments = [ ];
          };
          supervision = {
            executable = lib.getExe hostConfig.dotfiles.platform.supervise.package;
            completion = "require-drained";
          };
        };
      in
      lib.optionalAttrs (agentConfig.clients ? omp && agentConfig.clients.omp.runtime ? managed) {
        agent-evaluation-runtime-descriptor =
          assert homeConfig.home.file ? ".local/share/dotfiles-agent/bin/omp";
          assert ompWrapper != agentConfig.clientExecutables.omp;
          assert !lib.hasPrefix agentConfig.supply.root ompWrapper;
          assert artifact.format == "json";
          assert artifact.deployedAt == "${homeDir}/${descriptorPath}";
          assert toString artifact.source == toString deployedDescriptor;
          pkgs.runCommandLocal "check-agent-evaluation-runtime-descriptor"
            {
              nativeBuildInputs = [
                pkgs.coreutils
                pkgs.jq
              ];
              DESCRIPTOR = deployedDescriptor;
              EXPECTED = builtins.toJSON expected;
              SUPERVISE = expected.supervision.executable;
            }
            ''
              set -euo pipefail
              # 個別 field の検査は予算・model・資格情報・保存先の混入を見逃すため不可
              jq -e --argjson expected "$EXPECTED" '. == $expected' "$DESCRIPTOR" > /dev/null
              test "$(stat -L -c %a "$DESCRIPTOR")" = 444
              supervisor=$(jq -r '.supervision.executable' "$DESCRIPTOR")
              test "$supervisor" = "$SUPERVISE"
              "$supervisor" --require-drained --result "$PWD/result.json" -- ${pkgs.coreutils}/bin/true
              jq -e '.phase == "finished" and .completion == "require-drained" and .drained == true' \
                result.json > /dev/null
              touch "$out"
            '';
      }
    )
  ];
}
