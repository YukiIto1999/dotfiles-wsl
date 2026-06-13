{ pkgs }:

# @var@ テンプレートを展開した文字列
path: vars: builtins.readFile (pkgs.replaceVars path vars)
