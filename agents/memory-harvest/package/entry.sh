export PYTHONPATH="@journal@"
exec "@python@" "@source@/harvest.py" \
  --sessions-root "@sessionsRoot@" \
  --state-file "@stateFile@" \
  --lookback-days "@lookbackDays@" \
  --memory "@memory@" \
  --omp "@omp@" \
  --model "@model@" \
  --thinking "@thinking@" \
  "$@"
