"""Compare declared public sources without evaluating a flake or executing a package."""

import json
import re
import sys
from pathlib import Path
from urllib.error import URLError
from urllib.parse import quote
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[2]
API = "https://api.github.com/repos/"
# A fixed release revision follows releases, not the repository's default branch.
RELEASE_INPUTS = {"devenv", "orca"}
BRANCH_FOR_PIN = {"nixpkgs-unstable": "nixpkgs-unstable"}
PACKAGES = {
    "zvec-grep": ("toolchain/package/zvec-grep.nix", "npm", "@zvec/zvec-grep-linux-x64-gnu"),
    "anode": ("toolchain/package/anode.nix", "release", "skulitom/Anode"),
    "aspire-cli": ("toolchain/package/aspire-cli.nix", "release", "microsoft/aspire"),
    "memlab-mcp": ("capabilities/heap-diagnostics/memlab/mcp/package.nix", "npm", "@memlab/mcp-server"),
    "semgrep": ("toolchain/package/semgrep.nix", "pypi", "semgrep"),
    "agentgateway": ("platform/mcp/package/agentgateway.nix", "release", "agentgateway/agentgateway"),
}


def get(url):
    request = Request(url, headers={"User-Agent": "dotfiles-upstream-check"})
    with urlopen(request, timeout=12) as response:
        return json.load(response)


def npm_latest(package):
    return get("https://registry.npmjs.org/" + quote(package, safe="") + "/latest")["version"]


def package_version(name):
    path, kind, repository = PACKAGES[name]
    match = re.search(r'^\s*version\s*=\s*"([\w.+-]+)";', (ROOT / path).read_text(), re.M)
    if not match:
        raise ValueError(f"no literal version in {path}")
    if kind == "npm":
        latest = npm_latest(repository)
    elif kind == "pypi":
        latest = get(f"https://pypi.org/pypi/{repository}/json")["info"]["version"]
    else:
        latest = get(API + repository + "/releases/latest")["tag_name"].removeprefix("v")
    return match[1], latest


def input_revision(name, node):
    locked = node["locked"]
    original = node["original"]
    if name == "chromeDevtoolsMcp" and original["type"] == "tarball":
        match = re.fullmatch(r"https://registry\.npmjs\.org/chrome-devtools-mcp/-/chrome-devtools-mcp-([\w.+-]+)\.tgz", original["url"])
        if not match:
            raise ValueError("unrecognized npm source")
        return match[1], npm_latest("chrome-devtools-mcp")
    if original["type"] != "github":
        raise ValueError("no policy for " + original["type"])
    base = API + quote(original["owner"]) + "/" + quote(original["repo"])
    if name in RELEASE_INPUTS:
        ref = get(base + "/releases/latest")["tag_name"]
    else:
        ref = BRANCH_FOR_PIN.get(name, original.get("ref", "HEAD"))
    return locked["rev"], get(base + "/commits/" + quote(ref, safe=""))["sha"]


def main():
    lock = json.loads((ROOT / "flake.lock").read_text())
    nodes = lock["nodes"]
    inputs = nodes[lock["root"]]["inputs"]
    changed = failed = False
    for name in sorted(set(inputs) | set(PACKAGES)):
        try:
            current, candidate = (input_revision(name, nodes[inputs[name]]) if name in inputs else package_version(name))
            if not current or not candidate:
                raise ValueError("empty source version")
            same = current == candidate
            print(f"{'same' if same else 'different':10} {name:24} {current} {candidate}", flush=True)
            changed |= not same
        except (OSError, URLError, ValueError, KeyError, TypeError) as exc:
            print(f"unknown    {name:24} {exc}", flush=True)
            failed = True
    return 2 if failed else int(changed)


if __name__ == "__main__":
    sys.exit(main())
