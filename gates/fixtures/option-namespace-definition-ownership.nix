{
  lib,
  self,
  definitionFile,
  declarationFile ? "agents/module.nix",
  optionPath ? [
    "dotfiles"
    "agents"
    "fixture"
  ],
  optionType ? null,
  definitionValue ? "fixture",
}:

(lib.evalModules {
  modules = [
    {
      _file = "${self}/${declarationFile}";
      options = lib.setAttrByPath optionPath (
        lib.mkOption {
          type = if optionType == null then lib.types.str else optionType;
        }
      );
    }
    {
      _file = "${self}/${definitionFile}";
      config = lib.setAttrByPath optionPath (lib.mkDefault definitionValue);
    }
  ];
}).options
