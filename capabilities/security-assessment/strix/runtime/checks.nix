{ pkgs, ... }: {
  source = [
    {
      strix-runtime-behavior =
        pkgs.runCommandLocal "check-strix-runtime-behavior"
          {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.coreutils
              pkgs.python3
              pkgs.util-linux
            ];
          }
          ''
            ${pkgs.python3}/bin/python ${./fixtures}/runtime.py --entry ${./package/entry.sh}
            touch "$out"
          '';
    }
  ];
}
