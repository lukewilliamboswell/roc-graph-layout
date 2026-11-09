"""Run a released example with the suite-root working directory it documents."""

import os
import sys


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit("usage: run-example.py SUITE EXECUTABLE [ARG ...]")
    suite, executable, *arguments = sys.argv[1:]
    os.chdir(suite)
    os.execv(executable, [executable, *arguments])
