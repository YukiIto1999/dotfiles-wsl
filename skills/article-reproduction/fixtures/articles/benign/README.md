# Shellの出力を確認する

## 対象

Linux上でshellを使う読者が、外部fileやnetworkに依存せず、一行の出力を得る手順である。
以下は期待結果であり、この記事のfixtureを作成した時点の実行logではない。

## 前提

`sh`が利用可能で、POSIX.1-2017のshell構文とbuiltinの`printf`を使えることを前提とする。
追加runtime、資格情報、環境変数、sample fileは必要ない。
作業directoryは読み書きしないため、任意の新しい作業directoryで実行できる。
実行担当はOSと実際のshellの実装とversion、cwdを記録する。

## 操作

次のcommandは標準出力だけを書き、file、network、processの常駐状態を変更しない。

```sh
sh -c 'printf "%s\n" "reproduction-ok"'
```

## 期待結果

終了codeは0で、stderrは空になる。
stdoutは、末尾の改行を含めて次の一行と完全一致する。

<!-- output: benign-output -->
```text
reproduction-ok
```

生成物はなく、この終了codeと二つのstreamが成功条件である。
`sh`を起動できない場合は前提不足とし、別のshellや追加installで検査を通したことにしない。
