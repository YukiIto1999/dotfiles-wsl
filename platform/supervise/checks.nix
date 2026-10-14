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
      }
    )
  ];
}
