import json
import os
import signal
import sys
from pathlib import Path


if sys.argv[1:] == ["--control"]:
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
    while True:
        signal.pause()

if "--help" in sys.argv[1:]:
    sys.exit(0)
if "--version" in sys.argv[1:]:
    sys.exit(0)

config = Path(sys.argv[sys.argv.index("--config") + 1])
assert config.is_file()
assert config.stat().st_mode & 0o777 == 0o600
assert config.parent.stat().st_mode & 0o777 == 0o700
config.write_text(json.dumps({"env": {"LLM_API_KEY": os.environ["LLM_API_KEY"]}}))

signal.signal(signal.SIGTERM, signal.SIG_IGN)
signal.signal(signal.SIGINT, signal.SIG_IGN)
ready_read, ready_write = os.pipe()
descendant = os.fork()
if descendant == 0:
    os.close(ready_read)
    os.write(ready_write, b"ready")
    os.close(ready_write)
    while True:
        signal.pause()
os.close(ready_write)
assert os.read(ready_read, 5) == b"ready"
os.close(ready_read)
print(json.dumps({"child": os.getpid(), "descendant": descendant, "config": str(config)}), flush=True)
if os.environ["STRIX_FIXTURE_MODE"] == "normal":
    sys.exit(int(os.environ["STRIX_FIXTURE_STATUS"]))
while True:
    signal.pause()
