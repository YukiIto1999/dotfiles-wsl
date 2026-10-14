{
  configuration = [
    (
      {
        pkgs,
        hostConfig,
        ...
      }:
      let
        wrapper = hostConfig.dotfiles.platform.mcp.targets.memlab.executable;
      in
      {
        heap-diagnostics = pkgs.runCommandLocal "check-heap-diagnostics" { } ''
          ${pkgs.python3}/bin/python ${./package/check-server.py} \
            ${wrapper} ${pkgs.nodejs}/bin/node ${./package/heap-fixture.mjs}
          ${pkgs.python3}/bin/python ${./package/check-server.py} \
            ${wrapper} ${pkgs.nodejs}/bin/node ${./package/heap-fixture.mjs} --deadline-only
          touch $out
        '';
      }
    )
  ];
}
