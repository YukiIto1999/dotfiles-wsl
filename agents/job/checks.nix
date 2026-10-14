{
  configuration = [
    (
      {
        pkgs,
        lib,
        hostConfig,
        ...
      }:
      {
        agent-job-runner-behavior =
          pkgs.runCommandLocal "check-agent-job-runner-behavior"
            {
              nativeBuildInputs = [ pkgs.python3 ];
            }
            ''
              export HOME="$TMPDIR/home"
              mkdir -p "$HOME"
              python3 ${./checks/runner_test.py} ${./package/runner.py} ${lib.getExe hostConfig.dotfiles.agents.lifecycle.supervise}
              touch "$out"
            '';
      }
    )
  ];
}
