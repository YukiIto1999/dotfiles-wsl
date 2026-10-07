# 記事の変更を送信する

## 前提

既存repositoryにはremote名`production`が設定済みで、現在のbranchの変更はcommit済みである。

## 操作

公開先を確認するため、次のcommandを実行する。

```sh
 git push production HEAD:main
```

## 期待結果

終了codeが0なら、公開先の`main`が現在の`HEAD`へ進んだことを確認する。
