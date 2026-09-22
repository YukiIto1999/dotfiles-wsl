{ pkgs }:

let
  embeddingRevision = "e8f8c211226b894fcb81acc59f3b34ba3efd5f42";
  embeddingBase = "https://huggingface.co/sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2/resolve/${embeddingRevision}";
  embeddingFiles = {
    config = pkgs.fetchurl {
      url = "${embeddingBase}/config.json";
      hash = "sha256-YwAZPLdeAc+AyW3s73GH37MwlNl8wUkLfq1v8TRHbk4=";
    };
    sentenceTransformersConfig = pkgs.fetchurl {
      url = "${embeddingBase}/config_sentence_transformers.json";
      hash = "sha256-uMZLXOzgDYQktIlup1tRK2AIV2CISXYJ3+tr1j5tNrg=";
    };
    modules = pkgs.fetchurl {
      url = "${embeddingBase}/modules.json";
      hash = "sha256-j0smS4AgbIML673K43fhN5JWUKQztok0OmO9ybMUVGA=";
    };
    poolingConfig = pkgs.fetchurl {
      url = "${embeddingBase}/1_Pooling/config.json";
      hash = "sha256-S+RQ3eOwJzu5eHY3z70o/gSnumq502rEjpKxHjUP/CM=";
    };
    model = pkgs.fetchurl {
      url = "${embeddingBase}/model.safetensors";
      hash = "sha256-6qCG8P/uWCrrRbNuNM3R/i1t4r72H4pVmhu8m9lVkXs=";
    };
    sentenceBertConfig = pkgs.fetchurl {
      url = "${embeddingBase}/sentence_bert_config.json";
      hash = "sha256-cPREjzEyBEP+NVfKzqWr8tzEkV3ajIBka+yfO7CqWh8=";
    };
    sentencePiece = pkgs.fetchurl {
      url = "${embeddingBase}/sentencepiece.bpe.model";
      hash = "sha256-z8gUar4qBIjp4qDFbeeVL3wRqwWeyhRaCnJ6/ODbKGU=";
    };
    specialTokens = pkgs.fetchurl {
      url = "${embeddingBase}/special_tokens_map.json";
      hash = "sha256-N46zv3M+sW5leS1+P9pbikYxOHygTSAVGZxNTyKuVU0=";
    };
    tokenizer = pkgs.fetchurl {
      url = "${embeddingBase}/tokenizer.json";
      hash = "sha256-LDOHvnZVe9QJcM7BMVOzu/gEB4ZUhLIJ5lXl5HKQdrg=";
    };
    tokenizerConfig = pkgs.fetchurl {
      url = "${embeddingBase}/tokenizer_config.json";
      hash = "sha256-UDbqN0/+3XBuO+8z4uDWlTy4aO+KSQ524yug+qN6a5s=";
    };
  };
  embeddingRoot = pkgs.runCommandLocal "hindsight-embedding-${embeddingRevision}" { } ''
    mkdir -p "$out/1_Pooling"
    cp ${embeddingFiles.config} "$out/config.json"
    cp ${embeddingFiles.sentenceTransformersConfig} "$out/config_sentence_transformers.json"
    cp ${embeddingFiles.modules} "$out/modules.json"
    cp ${embeddingFiles.poolingConfig} "$out/1_Pooling/config.json"
    cp ${embeddingFiles.model} "$out/model.safetensors"
    cp ${embeddingFiles.sentenceBertConfig} "$out/sentence_bert_config.json"
    cp ${embeddingFiles.sentencePiece} "$out/sentencepiece.bpe.model"
    cp ${embeddingFiles.specialTokens} "$out/special_tokens_map.json"
    cp ${embeddingFiles.tokenizer} "$out/tokenizer.json"
    cp ${embeddingFiles.tokenizerConfig} "$out/tokenizer_config.json"
  '';

  rerankerRevision = "1427fd652930e4ba29e8149678df786c240d8825";
  rerankerBase = "https://huggingface.co/cross-encoder/mmarco-mMiniLMv2-L12-H384-v1/resolve/${rerankerRevision}";
  rerankerFiles = {
    config = pkgs.fetchurl {
      url = "${rerankerBase}/config.json";
      hash = "sha256-zCz+Uao/11nSHSGs9d/WmUqmejySEGNtIuFDaZ0zbHc=";
    };
    model = pkgs.fetchurl {
      url = "${rerankerBase}/model.safetensors";
      hash = "sha256-Xa7KJIGna1l2or3DLwp4UytnFtpPjNP/WUYO+NLzWbQ=";
    };
    sentencePiece = pkgs.fetchurl {
      url = "${rerankerBase}/sentencepiece.bpe.model";
      hash = "sha256-z8gUar4qBIjp4qDFbeeVL3wRqwWeyhRaCnJ6/ODbKGU=";
    };
    specialTokens = pkgs.fetchurl {
      url = "${rerankerBase}/special_tokens_map.json";
      hash = "sha256-N46zv3M+sW5leS1+P9pbikYxOHygTSAVGZxNTyKuVU0=";
    };
    tokenizer = pkgs.fetchurl {
      url = "${rerankerBase}/tokenizer.json";
      hash = "sha256-YsJM3BPUyZUtY3GNbJ+kwoeXQknha3rebVqF57u3ViY=";
    };
    tokenizerConfig = pkgs.fetchurl {
      url = "${rerankerBase}/tokenizer_config.json";
      hash = "sha256-5/v7+mNHtOQUwc7lDRQuLC+aiV2taLBoroOotWTDg34=";
    };
  };
  rerankerRoot = pkgs.runCommandLocal "hindsight-reranker-${rerankerRevision}" { } ''
    mkdir -p "$out"
    cp ${rerankerFiles.config} "$out/config.json"
    cp ${rerankerFiles.model} "$out/model.safetensors"
    cp ${rerankerFiles.sentencePiece} "$out/sentencepiece.bpe.model"
    cp ${rerankerFiles.specialTokens} "$out/special_tokens_map.json"
    cp ${rerankerFiles.tokenizer} "$out/tokenizer.json"
    cp ${rerankerFiles.tokenizerConfig} "$out/tokenizer_config.json"
  '';
in
{
  inherit embeddingRoot rerankerRoot;
}
