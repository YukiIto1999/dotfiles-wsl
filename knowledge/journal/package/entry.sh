export PYTHONTZPATH="@zoneinfo@"
export PI_CONFIG_FILES="${PI_CONFIG_FILES:+${PI_CONFIG_FILES}:}@modelRouting@"
exec "@python@" "@source@/journal.py" \
  --sessions-root "@sessionsRoot@" \
  --journal-dir "@journalDir@" \
  --machine-name "@machineName@" \
  --timezone "@timeZone@" \
  --start-hour "@startHour@" \
  --lookback-days "@lookbackDays@" \
  --model "@model@" \
  --thinking "@thinking@" \
  --memory "@memory@" \
  --memory-state "@memoryState@" \
  "$@"
