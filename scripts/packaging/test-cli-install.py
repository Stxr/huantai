#!/usr/bin/env python3
"""Exercise the shipped installer without touching the user's shell configuration."""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="huantai-cli-") as temporary:
    fixture = Path(temporary)
    resources = fixture / "换台.app/Contents/Resources"
    executable = fixture / "换台.app/Contents/MacOS/ht"
    resources.mkdir(parents=True)
    executable.parent.mkdir()
    executable.write_text("#!/bin/sh\nprintf 'fixture ht\\n'\n")
    executable.chmod(0o755)
    installer = resources / "install-cli.sh"
    shutil.copy(root / "Sources/HuantaiApp/Resources/install-cli.sh", installer)
    directory = fixture / "user's bin"
    profile = fixture / "shell profile"
    profile.write_text("# existing settings\nexport HUANTAI_TEST_PRESERVED=yes\n")
    args = ["/bin/bash", str(installer), "--bin-dir", str(directory), "--profile", str(profile), "--shell", "/bin/zsh"]
    subprocess.run(args, check=True)
    assert (directory / "ht").resolve() == executable.resolve()
    assert len(list(fixture.glob("shell profile.huantai-backup.*"))) == 1
    original = profile.read_bytes()
    subprocess.run(args, check=True, capture_output=True)
    assert profile.read_bytes() == original
    for shell in ["/bin/zsh", "/bin/bash"]:
        result = subprocess.run([shell, "-c", 'source "$1"; test "$HUANTAI_TEST_PRESERVED" = yes && ht', "test", str(profile)], check=True, capture_output=True, text=True)
        assert result.stdout == "fixture ht\n"
    (directory / "ht").unlink()
    (directory / "ht").write_text("unrelated tool")
    assert subprocess.run(args, capture_output=True).returncode != 0
    assert (directory / "ht").read_text() == "unrelated tool"
    assert profile.read_bytes() == original
    fish = shutil.which("fish")
    if fish:
        fish_profile = fixture / "fish config"
        (directory / "ht").unlink()
        subprocess.run(args[:-4] + ["--profile", str(fish_profile), "--shell", fish], check=True, capture_output=True)
        result = subprocess.run([fish, "-c", 'source $argv[1]; ht', str(fish_profile)], check=True, capture_output=True, text=True)
        assert result.stdout == "fixture ht\n"
    print("CLI installer: idempotency, shell quoting, PATH, profile backup and conflict protection passed.")
