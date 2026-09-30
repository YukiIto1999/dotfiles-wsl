{
  lib,
  fetchurl,
  runCommandLocal,
  writeShellApplication,
  zvecGrep,
  port,
}:

let
  # zg の catalog にある既定 model local/potion-code-16m-v2 の repo と revision。
  # front は network を持たず、zg は空でない file なら中身を確かめずに使うので、
  # 初回 download も壊れた cache の検出も zg に任せられない。
  modelRepo = "minishlab/potion-code-16M-v2";
  modelRevision = "e9d2a44ca6a05ac6685f3b23709ea57eb7352d5b";
  modelBase = "https://huggingface.co/${modelRepo}/resolve/${modelRevision}";
  modelFile = fetchurl {
    url = "${modelBase}/model.safetensors";
    hash = "sha256-dc96bCFxsjCtGbHn2OCxruhtpaAq+OfKzt2ZIdInYjw=";
  };
  tokenizerFile = fetchurl {
    url = "${modelBase}/tokenizer.json";
    hash = "sha256-EHu9y61L/x0pm3pMOi+xfFKJBoi33Q5Mneq3nTxPPUU=";
  };
  # zg の model cache と同じ配置にする。tokenizer_config.json は上流に無く、zg が書く内容を置く
  modelCache = runCommandLocal "zvec-grep-model-cache-${modelRevision}" { } ''
    model_dir="$out/model2vec/${lib.replaceStrings [ "/" ] [ "--" ] modelRepo}/${modelRevision}"
    mkdir -p "$model_dir/tokenizer"
    cp ${modelFile} "$model_dir/model.safetensors"
    cp ${tokenizerFile} "$model_dir/tokenizer/tokenizer.json"
    printf '%s\n' '{"tokenizer_class":"PreTrainedTokenizer"}' > "$model_dir/tokenizer/tokenizer_config.json"
  '';
in
writeShellApplication {
  name = "zvec-grep-mcp";
  # --model-cache は global config と ZVEC_GREP_MODEL_CACHE より優先される
  text = ''
    exec ${lib.getExe zvecGrep} server run --listen 127.0.0.1:${toString port} --mcp-toolset agent --model-cache ${modelCache}
  '';
  passthru = { inherit modelCache; };
}
