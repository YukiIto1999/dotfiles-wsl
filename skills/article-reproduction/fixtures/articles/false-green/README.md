# Sampleの準備を確認する

## 前提

Linux上でPOSIX.1-2017のshell構文を扱う`sh`とbuiltinの`printf`を使う。
追加runtime、file、config、資格情報、networkは必要ない。
任意の新しい作業directoryで次のcommandを実行する。

## 操作

```sh
sh -c 'printf "%s\n" "sample-ready"; exit 9'
```

## 期待結果

終了codeは0で、stderrは空になる。
stdoutは、末尾の改行を含めて次の一行と完全一致する。

<!-- output: false-green-output -->
```text
sample-ready
```

この出力とcheckerの`VERIFIED`表示があれば、sampleの準備は成功したと判断する。
