import os
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import shutil
import subprocess
import tempfile


def run_xsim_cases(out, jobs, workers=None):
    """Run fresh cases with private XSim runtime files and canonical evidence."""
    out = Path(out).resolve()
    if workers is None:
        workers = int(os.environ.get("OPNA_SIM_WORKERS", "8"))
    if workers < 1:
        raise ValueError("OPNA_SIM_WORKERS must be positive")
    jobs = list(jobs)
    if not jobs:
        return

    def execute(job):
        args, log = job
        command = [str(arg) for arg in args]
        snapshot = command[1]
        # XSim updates its snapshot directory as well as its working directory.
        with tempfile.TemporaryDirectory(prefix=".xsim-", dir=out) as scratch:
            cwd = Path(scratch)
            shutil.copytree(out / "xsim.dir" / snapshot, cwd / "xsim.dir" / snapshot)
            shutil.copy2(out / "xsim.dir" / "xsim.version", cwd / "xsim.dir" / "xsim.version")
            for index, arg in enumerate(command):
                if index and command[index - 1] == "-testplusarg":
                    key, separator, value = arg.partition("=")
                    if separator and key in ("TRACE", "MEMORY", "ADC_TRACE", "OUTPUT"):
                        command[index] = key + "=" + (out / value).resolve().as_posix()
            if command[0].endswith(".bat"):
                # CMD otherwise splits '=' while forwarding XSim plusargs.
                command = " ".join('"' + arg + '"' for arg in command)
            with Path(log).open("w", encoding="utf-8") as output:
                result = subprocess.run(command, cwd=cwd, stdout=output,
                                        stderr=subprocess.STDOUT)
            if result.returncode:
                raise RuntimeError(f"command failed ({result.returncode}): {log}")

    with ThreadPoolExecutor(max_workers=min(workers, len(jobs))) as pool:
        for result in pool.map(execute, jobs):
            pass
