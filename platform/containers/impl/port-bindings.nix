{ lib }:

let
  falseBooleanValues = [
    "0"
    "F"
    "False"
    "FALSE"
    "f"
    "false"
  ];
  publishAllDisabled =
    option:
    (lib.hasPrefix "-P=" option && lib.elem (lib.removePrefix "-P=" option) falseBooleanValues)
    || (
      lib.hasPrefix "--publish-all=" option
      && lib.elem (lib.removePrefix "--publish-all=" option) falseBooleanValues
    );
  publishAllRequested =
    option:
    option == "-P"
    || option == "--publish-all"
    || (lib.hasPrefix "-P=" option && !lib.elem (lib.removePrefix "-P=" option) falseBooleanValues)
    || (
      lib.hasPrefix "--publish-all=" option
      && !lib.elem (lib.removePrefix "--publish-all=" option) falseBooleanValues
    );
  extraOptionPortBindings =
    container:
    let
      options = container.extraOptions or [ ];
    in
    lib.concatLists (
      lib.imap0 (
        index: option:
        if publishAllDisabled option then
          [ ]
        else if publishAllRequested option then
          [ "<publish-all>" ]
        else if option == "-p" || option == "--publish" then
          [ (if index + 1 < builtins.length options then builtins.elemAt options (index + 1) else "") ]
        else if lib.hasPrefix "-p=" option then
          [ (lib.removePrefix "-p=" option) ]
        else if lib.hasPrefix "-p" option then
          [ (lib.removePrefix "-p" option) ]
        else if lib.hasPrefix "--publish=" option then
          [ (lib.removePrefix "--publish=" option) ]
        else if
          lib.hasPrefix "-" option
          && !lib.hasPrefix "--" option
          && (lib.hasInfix "p" option || lib.hasInfix "P" option)
        then
          [ "<publish-option-cluster>" ]
        else
          [ ]
      ) options
    );
in
{
  publishedPortBindings = container: (container.ports or [ ]) ++ extraOptionPortBindings container;
}
