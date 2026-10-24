#!/usr/bin/env python3
"""Runs a command whose stdout is a pseudo-terminal, copying it to our stdout as it comes.

Programs that buffer a pipe in blocks (xcbeautify holds everything until it exits) write a
terminal line by line, so this makes them stream into a pipe or a CI log. Only stdout and
stderr are the terminal: stdin stays as it is, so nothing is echoed, and output processing is
off, so lines keep their plain "\\n". Exits with the command's status (128 + N when a signal
N ended it). The command runs in a process group of its own (it is not in the watchdog's), and
INT, TERM and HUP are passed on to that group; 5 s later anything left of it is killed. The
command is always reaped.

Usage: linebuffered.py <command> [args...]
"""

import os
import pty
import signal
import subprocess
import sys
import termios


def main() -> int:
    master, slave = pty.openpty()
    attrs = termios.tcgetattr(slave)
    attrs[1] &= ~termios.OPOST  # no "\n" -> "\r\n"
    termios.tcsetattr(slave, termios.TCSANOW, attrs)
    forwarded = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)

    def default_signals():
        # A background job in a script starts with INT ignored; the command must not inherit that.
        for signum in forwarded:
            signal.signal(signum, signal.SIG_DFL)

    child = subprocess.Popen(
        sys.argv[1:],
        stdout=slave,
        stderr=slave,
        close_fds=True,
        preexec_fn=default_signals,
        start_new_session=True,
    )
    os.close(slave)

    def signal_group(signum):
        try:
            os.killpg(child.pid, signum)
        # macOS answers EPERM, not ESRCH, when every member of the group has exited but isn't
        # reaped yet: the group is gone either way.
        except (ProcessLookupError, PermissionError):
            pass

    def forward(signum, _frame):
        signal_group(signum)
        signal.alarm(5)  # anything still there in 5 s is killed

    def kill(_signum, _frame):
        signal_group(signal.SIGKILL)

    for signum in forwarded:
        signal.signal(signum, forward)
    signal.signal(signal.SIGALRM, kill)

    out = sys.stdout.buffer
    try:
        while True:
            try:
                data = os.read(master, 65536)
            except InterruptedError:
                continue
            except OSError:  # EIO once the child closed the terminal
                break
            if not data:
                break
            out.write(data)
            out.flush()
    finally:
        os.close(master)
        if child.poll() is None:
            signal_group(signal.SIGTERM)
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                signal_group(signal.SIGKILL)
        status = child.wait()
    # A signal shows as -N; report it the way a shell does.
    return 128 - status if status < 0 else status


if __name__ == "__main__":
    sys.exit(main())
