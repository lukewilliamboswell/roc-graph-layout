"""Finish one owned child group without accepting uncertain cleanup."""

import os
import signal


def cleanup_child_group(process, selector):
    # macOS can reject SIGKILL for a zombie-only group. Reap first and excuse
    # that error only after signal 0 proves the entire group no longer exists.
    # Signal descendants even when the leader exited; never retry SIGKILL.
    signal_error = None
    try:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except OSError as error:
            signal_error = error
        process.wait(timeout=5)
        if signal_error is not None:
            if not isinstance(signal_error, PermissionError):
                raise signal_error
            try:
                os.killpg(process.pid, 0)
            except ProcessLookupError:
                pass
            else:
                # A live or inaccessible group cannot satisfy admission.
                raise signal_error
    finally:
        try:
            selector.close()
        finally:
            try:
                process.stdout.close()
            finally:
                process.stderr.close()
