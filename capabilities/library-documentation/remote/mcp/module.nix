{
  config,
  lib,
  pkgs,
  ...
}:

let
  enabled = builtins.elem "library-documentation" config.dotfiles.capabilities.resolved;
  remote = name: url: port: {
    provider = name;
    inherit port;
    exposure = "default";
    serverLifecycle = "session";
    lazyDiscovery = true;
    # network の無い build sandbox では取得できないため、公開 endpoint を資格情報なしの proxy で一度だけ取得した
    # 応答を置く。endpoint 側が変わると seed の更新まで最初の実呼出しの照合で失敗し、未知の tool を通さない
    discoverySeed = ./discovery/${name}.json;
    needsNetwork = true;
    executable = toString (
      pkgs.writeShellScript "mcp-${name}" ''
        unset API_ACCESS_TOKEN
        exec ${
          lib.escapeShellArgs [
            (lib.getExe pkgs.mcp-proxy)
            "--transport=streamablehttp"
            url
          ]
        }
      ''
    );
  };
in
{
  config = lib.mkIf enabled {
    dotfiles.platform.mcp.targets = {
      deepwiki = remote "deepwiki" "https://mcp.deepwiki.com/mcp" 8772;
      microsoft-learn = remote "microsoft-learn" "https://learn.microsoft.com/api/mcp" 8773;
    };
  };
}
