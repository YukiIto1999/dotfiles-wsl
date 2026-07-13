{
  lib,
  rustPlatform,
  fetchFromGitHub,
  cmake,
  perl,
}:

rustPlatform.buildRustPackage rec {
  pname = "agentgateway";
  version = "1.3.1";

  src = fetchFromGitHub {
    owner = "agentgateway";
    repo = "agentgateway";
    tag = "v${version}";
    hash = "sha256-Sx/7ClG3D+o1p6+tam61O3K0EfcaDe7xKXnodUxwOtE=";
  };

  cargoHash = "sha256-AtdPXCxSf/PHHnCDOzLojQyRRbXraObpim6RNF2gybw=";

  # idle reap 後 session の 404 化と backend error の 200 化
  patches = [ ./mcp-session-recovery.patch ];

  # aws-lc-sys / jemalloc-sys の C ビルド
  nativeBuildInputs = [
    cmake
    perl
  ];

  cargoBuildFlags = [
    "-p"
    "agentgateway-app"
  ];

  # tokio unstable cfg と sandbox で欠落する build info
  env = {
    RUSTFLAGS = "--cfg tokio_unstable";
    AGENTGATEWAY_BUILD_buildVersion = version;
    AGENTGATEWAY_BUILD_buildGitRevision = "v${version}";
  };

  doCheck = false;

  meta.mainProgram = "agentgateway";
}
