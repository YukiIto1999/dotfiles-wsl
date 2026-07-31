{
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

  # idle reap 後 session の 404 化と backend error の 200 化、downstream SSE の keepalive と active-stream guard
  patches = [
    ./mcp-session-recovery.patch
    ./mcp-downstream-lifecycle.patch
  ];

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

  doCheck = true;

  # patch が固定する downstream session lifecycle の回帰だけを実行する
  cargoTestFlags = [
    "-p"
    "agentgateway"
    "--lib"
  ];
  checkFlags = [ "downstream_lifecycle_" ];

  meta.mainProgram = "agentgateway";
}
