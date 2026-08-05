vars: text:
builtins.replaceStrings (map (name: "@${name}@") (
  builtins.attrNames vars
)) (builtins.attrValues vars) text
