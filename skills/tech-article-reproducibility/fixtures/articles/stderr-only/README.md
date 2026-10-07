# Sampleの出力を確認する

## 前提

Linux上でPOSIX.1-2017のshell構文を扱う`sh`とbuiltinの`printf`を使う。
任意の作業directoryで実行でき、追加runtime、file、資格情報、networkは必要ない。

## 操作

```sh
sh -c 'printf "%s\n" "sample-ready" >&2'
```

## 期待結果

終了codeは0で、stderrは空になる。
stdoutは、末尾の改行を含めて次の一行と完全一致する。

<!-- output: stdout-output -->
```text
sample-ready
```

出力とcheckerの成功表示で確認を終える。
