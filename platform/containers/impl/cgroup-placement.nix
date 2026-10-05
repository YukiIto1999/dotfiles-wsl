{
  # 宣言外の container と上限を分け合うため daemon の既定の slice は不可
  declared = "system.slice";
  # 基盤と同じ上限なしの配置になるため docker の既定の system.slice は不可
  undeclared = "containers.slice";
}
