{
  hostConfig,
  hostOptions,
  pkgs,
  ...
}:

let
  runtime = hostConfig.dotfiles.capabilities.browser-runtime.package;
  option = hostOptions.dotfiles.capabilities.browser-runtime.package;
in
{
  browser-runtime-chromium-contract =
    assert runtime == pkgs.chromium;
    assert option.type.name == "package";
    assert option.readOnly or false;
    assert option.internal or false;
    pkgs.runCommandLocal "check-browser-runtime-chromium-contract" { } "touch $out";
}
