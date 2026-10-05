import base64
import os
from pathlib import Path
import re
import subprocess
import tempfile


launcher = os.environ["WSLVIEW_LAUNCHER"]
capture = Path(os.environ["WSLVIEW_CAPTURE"])
path_capture = Path(os.environ["WSLVIEW_PATH_CAPTURE"])


def invoke(arguments, status=0, environment=None):
    """Run the launcher and check its public exit status for the supplied arguments."""
    capture.unlink(missing_ok=True)
    path_capture.unlink(missing_ok=True)
    result = subprocess.run(
        [launcher, *arguments],
        env=os.environ | (environment or {}),
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == status, (arguments, result.returncode, result.stderr)
    return result


def assert_forwarded(target):
    """Check that Windows receives one inert UTF-8 target without an argument list."""
    arguments = capture.read_bytes().split(b"\0")
    assert arguments[-1] == b""
    assert arguments[:-2] == [b"-NoLogo", b"-NoProfile", b"-NonInteractive", b"-Command"]
    script = arguments[-2].decode()
    encoded = re.search(r"FromBase64String\('([A-Za-z0-9+/=]+)'\)", script)
    assert encoded is not None, script
    assert base64.b64decode(encoded[1]).decode() == target
    assert "UseShellExecute" in script
    assert "ArgumentList" not in script
    assert "catch" in script and "exit 1" in script


assert "Usage:" in invoke(["--help"]).stdout
assert not capture.exists()
for arguments in ([], ["one", "two"], ["--unknown"], [""], ["https://example.com/\n"], ["--"]):
    invoke(arguments, status=2)
    assert not capture.exists()
    assert not path_capture.exists()

for target in (
    "https://example.com/?a=1&b='quoted';$value#fragment",
    "mailto:example@example.com?subject=日本語 with spaces",
    "file:///C:/Users/Example/document.txt",
    r"C:\Users\Example\日本語 & 'quoted' [name];$.txt",
    r"\\server\share\directory with spaces",
):
    invoke([target])
    assert_forwarded(target)
    assert not path_capture.exists()

with tempfile.TemporaryDirectory() as temporary:
    directory = Path(temporary) / "日本語 & 'quoted' [name];$"
    directory.mkdir()
    document = directory / "document.txt"
    document.write_text("Local launcher fixture\n")
    for target in (directory, document):
        invoke([str(target)])
        assert path_capture.read_text() == str(target.resolve())
        assert_forwarded(os.environ["WSLVIEW_WINDOWS_PATH"])
    dash_file = directory / "-leading-dash.txt"
    dash_file.touch()
    previous_directory = Path.cwd()
    os.chdir(directory)
    try:
        invoke(["--", dash_file.name])
        assert path_capture.read_text() == str(dash_file.resolve())
        assert_forwarded(os.environ["WSLVIEW_WINDOWS_PATH"])
    finally:
        os.chdir(previous_directory)
    invoke([str(document)], status=1, environment={"WSLVIEW_PATH_STATUS": "18"})
    assert not capture.exists()
    invoke([str(directory / "missing")], status=1)
    assert not capture.exists()

invoke(["https://example.com/"], status=17, environment={"WSLVIEW_WINDOWS_STATUS": "17"})
assert_forwarded("https://example.com/")
