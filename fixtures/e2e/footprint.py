"""Oops's footprint, for run.py's soak runs."""

import subprocess


def resources():
    """Oops's footprint (MB), threads, open files and child processes, or None when it isn't running."""
    pid = subprocess.run(["pgrep", "-x", "oops"], capture_output=True, text=True).stdout.split()
    if not pid:
        return None
    pid = pid[0]
    footprint = subprocess.run(["footprint", "-p", pid], capture_output=True, text=True).stdout
    mb = next((line.split()[1] for line in footprint.splitlines() if "phys_footprint:" in line), "?")
    threads = len(subprocess.run(["ps", "-M", "-p", pid], capture_output=True, text=True).stdout.splitlines()) - 1
    files = len(subprocess.run(["lsof", "-p", pid], capture_output=True, text=True).stdout.splitlines()) - 1
    children = len(subprocess.run(["pgrep", "-P", pid], capture_output=True, text=True).stdout.split())
    return {"footprint_mb": mb, "threads": threads, "open_files": files, "children": children}
