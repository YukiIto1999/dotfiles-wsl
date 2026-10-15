{ pkgs, lib, ... }:
{
  source = [
    (
      let
        supervise =
          (lib.evalModules {
            specialArgs = { inherit pkgs; };
            modules = [ ./module.nix ];
          }).config.dotfiles.platform.supervise.package;
      in
      {
        supervise-child-ownership =
          pkgs.runCommandLocal "check-supervise-child-ownership"
            {
              nativeBuildInputs = with pkgs; [
                bash
                coreutils
                jq
                util-linux
              ];
              SUPERVISE = lib.getExe supervise;
            }
            ''
              bash ${./fixtures/supervise.sh}
              touch $out
            '';

        supervise-drain-transition =
          pkgs.runCommandLocal "check-supervise-drain-transition"
            {
              nativeBuildInputs = [ pkgs.python3 ];
            }
            ''
              python3 ${./fixtures/drain_transition.py} ${./impl/supervise.py}
              touch $out
            '';
      }
    )
  ];
}
