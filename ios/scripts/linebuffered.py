#!/usr/bin/env python3
"""Runs a command whose stdout is a pseudo-terminal, copying it to our stdout as it comes.

Programs that buffer a pipe in blocks (xcbeautify holds everything until it exits) write a
terminal line by line, so this makes them stream into a pipe or a CI log. Only stdout and
stderr are the terminal: stdin stays as it is, so nothing is echoed, and output processing is
off, so lines keep their plain "\\n". Exits with the command's status.

Usage: linebuffered.py <command> [args...]
"""

import os
import pty
import subprocess
import sys
import termios


def main() -> int:
    master, slave = pty.openpty()
    attrs = termios.tcgetattr(slave)
    attrs[1] &= ~termios.OPOST  # no "\n" -> "\r\n"
    termios.tcsetattr(slave, termios.TCSANOW, attrs)
    child = subprocess.Popen(sys.argv[1:], stdout=slave, stderr=slave, close_fds=True)
    os.close(slave)
    out = sys.stdout.buffer
    while True:
        try:
            data = os.read(master, 65536)
        except OSError:  # EIO once the child closed the terminal
            break
        if not data:
            break
        out.write(data)
        out.flush()
    os.close(master)
    return child.wait()


if __name__ == "__main__":
    sys.exit(main())
