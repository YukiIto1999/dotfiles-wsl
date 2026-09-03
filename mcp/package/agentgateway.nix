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

  patches = [
    ./agentgateway/mcp-session-recovery.patch
    ./agentgateway/mcp-downstream-lifecycle.patch
    ./agentgateway/mcp-loopback-bind.patch
  ];

  nativeBuildInputs = [
    cmake
    perl
  ];

  cargoBuildFlags = [
    "-p"
    "agentgateway-app"
  ];

  env = {
    RUSTFLAGS = "--cfg tokio_unstable";
    AGENTGATEWAY_BUILD_buildVersion = version;
    AGENTGATEWAY_BUILD_buildGitRevision = "v${version}";
  };

  doCheck = true;

  cargoTestFlags = [
    "-p"
    "agentgateway"
    "--lib"
  ];
  checkFlags = [ "downstream_lifecycle_" ];

  meta.mainProgram = "agentgateway";
}
