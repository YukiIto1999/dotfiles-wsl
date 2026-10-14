[
  {
    name = "devenv";
    substituter = "https://devenv.cachix.org";
    publicKey = "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=";
  }
  {
    name = "nix-community";
    substituter = "https://nix-community.cachix.org";
    publicKey = "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs=";
  }
  # llm-agents.nix の flake nixConfig が宣言する cache。omp と codex を source から build しないために必要
  {
    name = "llm-agents";
    substituter = "https://cache.numtide.com";
    publicKey = "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g=";
  }
]
