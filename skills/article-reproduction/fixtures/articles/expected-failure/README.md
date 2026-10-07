# 非zeroの終了を観測する

## 前提

Linux上でPOSIX.1-2017のshell構文を扱う`sh`とbuiltinの`printf`を使う。
任意の作業directoryで実行でき、追加runtime、file、資格情報、networkは必要ない。

## 操作

この手順の到達点は、意図したエラーの終了codeとstderrを観測することである。

```sh
sh -c 'printf "%s\n" "intentional-error" >&2; exit 9'
```

## 期待結果

終了codeは9で、stdoutは空になる。
stderrは、末尾の改行を含む`intentional-error`の一行と完全一致する。
生成物はなく、この期待した失敗を観測すれば手順の再現は成功となる。
