#!/usr/bin/env python3
"""
Establish an authenticated SSH ControlMaster socket via password auth, for
devices in this project where key-based auth isn't set up and sshpass/
expect/pexpect aren't available in this environment.

Usage:
    python3 ssh_master.py <user>@<host> <password> [socket_path]

Once this exits 0, reuse the socket for fast, binary-safe follow-up
commands with no further password prompt:
    ssh -S <socket_path> <user>@<host> '<command>'
    scp -o ControlPath=<socket_path> local_file <user>@<host>:remote/path

Socket paths must stay under ~108 bytes (AF_UNIX path limit) -- default to
a short path directly under /tmp, never this project's long scratch paths.

The master connection uses ControlPersist=600 (~10min) and has been
observed to drop on its own around that mark, sometimes sooner under
device load -- if a follow-up ssh/scp using -S fails, just rerun this
script (it removes a stale socket file first).
"""
import os
import pty
import re
import sys
import time

PASSWORD_PROMPT = re.compile(rb"[Pp]assword:\s*$")


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: ssh_master.py <user>@<host> <password> [socket_path]", file=sys.stderr)
        return 1

    target = sys.argv[1]
    password = sys.argv[2]
    sock = sys.argv[3] if len(sys.argv) > 3 else "/tmp/ck_ssh_ctrl.sock"

    if os.path.exists(sock):
        os.remove(sock)

    cmd = [
        "ssh", "-M", "-S", sock, "-N", "-f",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ControlPersist=600",
        "-o", "ConnectTimeout=10",
        target,
    ]

    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(cmd[0], cmd)
        os._exit(127)

    buf = b""
    sent_password = False
    deadline = time.time() + 20
    while time.time() < deadline:
        try:
            chunk = os.read(fd, 1024)
        except OSError:
            break
        if not chunk:
            break
        buf += chunk
        if not sent_password and PASSWORD_PROMPT.search(buf):
            os.write(fd, (password + "\n").encode())
            sent_password = True
            buf = b""

    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass

    # -f backgrounds and detaches once authenticated; give the socket a
    # moment to actually materialize on disk before checking for it.
    for _ in range(10):
        if os.path.exists(sock):
            print(f"OK: control socket at {sock}")
            return 0
        time.sleep(0.5)

    print("FAILED: no control socket created", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
