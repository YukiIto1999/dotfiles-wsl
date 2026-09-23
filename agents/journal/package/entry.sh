export PYTHONTZPATH="@zoneinfo@"
exec "@python@" "@source@/journal.py" \
  --sessions-root "@sessionsRoot@" \
  --journal-dir "@journalDir@" \
  --machine-command "@machineCommand@" \
  --timezone "@timeZone@" \
  --start-hour "@startHour@" \
  --lookback-days "@lookbackDays@" \
  --omp "@omp@" \
  --model "@model@" \
  --thinking "@thinking@" \
  "$@"
