export PYTHONTZPATH="@zoneinfo@"
exec "@python@" "@source@/journal.py" \
  --sessions-root "@sessionsRoot@" \
  --journal-dir "@journalDir@" \
  --machine-name "@machineName@" \
  --timezone "@timeZone@" \
  --start-hour "@startHour@" \
  --lookback-days "@lookbackDays@" \
  --model "@model@" \
  --thinking "@thinking@" \
  "$@"
