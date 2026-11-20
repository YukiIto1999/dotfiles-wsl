export PYTHONPATH="@journal@"
export PI_CONFIG_FILES="${PI_CONFIG_FILES:+${PI_CONFIG_FILES}:}@modelRouting@"
exec "@python@" "@source@/harvest.py" \
  --sessions-root "@sessionsRoot@" \
  --state-file "@stateFile@" \
  --lookback-days "@lookbackDays@" \
  --memory "@memory@" \
  --model "@model@" \
  --thinking "@thinking@" \
  "$@"
