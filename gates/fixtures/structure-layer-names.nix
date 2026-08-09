{
  valid = [
    {
      name = "module.nix";
      kind = "regular";
      hasChildModule = false;
    }
    {
      name = "shared";
      kind = "directory";
      hasChildModule = false;
    }
    {
      name = "runtime";
      kind = "directory";
      hasChildModule = false;
    }
    {
      name = "child";
      kind = "directory";
      hasChildModule = true;
    }
    {
      name = ".child";
      kind = "directory";
      hasChildModule = true;
    }
  ];

  invalid = [
    {
      name = ".hidden";
      kind = "regular";
      hasChildModule = false;
    }
    {
      name = ".hidden-directory";
      kind = "directory";
      hasChildModule = false;
    }
    {
      name = "orphan";
      kind = "directory";
      hasChildModule = false;
    }
  ];
}
