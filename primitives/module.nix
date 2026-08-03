_:

{
  # 複数 unit の script が取り込む shell primitive。rebuild の状態機械は
  # rebuild が持ち、汎用の二つだけをここが供給する
  config.my.contract.primitives.libraries = {
    atomicFile = ./impl/lib/atomic-file.sh;
    operationLock = ./impl/lib/operation-lock.sh;
  };
}
