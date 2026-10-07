# Sampleをbuildする

## 前提

Linuxと`sh`があれば実行できる。
空の新しい作業directoryから始める。
追加installやnetwork接続は必要ない。

## 操作

次のcommandでsampleをbuildする。

```sh
sh ./build-article.sh samples/input.txt
```

## 期待結果

終了codeは0で、stderrは空になり、stdoutに`build-ok`の一行が出る。
作業directoryに`result.txt`が生成され、その内容は改行を含む`sample-ready`の一行になる。
