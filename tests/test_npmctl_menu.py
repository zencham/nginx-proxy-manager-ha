#!/usr/bin/env python3
"""Regression test for the npmctl interactive menu.

Drives ./npmctl (no args) inside a real pseudo-terminal, selects the first menu
item with Enter, and asserts the selection dispatches exactly that command —
guarding against the bug where ui_menu's rendered output was captured as the
'choice', producing 'Unknown command: Choose an action: ...'.

Runs entirely in NPMCTL_DRY_RUN=1, so nothing touches ansible or production.
"""
import os
import pty
import select
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def drive():
    env = dict(os.environ, NPMCTL_DRY_RUN="1", TERM="xterm")
    pid, fd = pty.fork()
    if pid == 0:  # child
        os.chdir(REPO)
        os.execvpe("./npmctl", ["./npmctl"], env)
        os._exit(127)

    buf = b""
    deadline = time.time() + 15
    sent_enter = False
    try:
        while time.time() < deadline:
            r, _, _ = select.select([fd], [], [], 0.5)
            if fd in r:
                try:
                    chunk = os.read(fd, 4096)
                except OSError:
                    break
                if not chunk:
                    break
                buf += chunk
                text = buf.decode("utf-8", "replace")
                # Once the menu is drawn, press Enter to select the first item (deploy).
                if not sent_enter and "Choose an action" in text:
                    time.sleep(0.2)
                    os.write(fd, b"\r")
                    sent_enter = True
                # After deploy starts in dry-run, we've proven dispatch worked.
                if "would-run: ansible-playbook drift_check.yml" in text:
                    break
    finally:
        try:
            os.write(fd, b"\x03")  # Ctrl-C to exit the menu loop
        except OSError:
            pass
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            os.waitpid(pid, 0)
        except OSError:
            pass

    return buf.decode("utf-8", "replace")


def main():
    out = drive()
    failures = []
    if "would-run: ansible-playbook drift_check.yml" not in out:
        failures.append("selecting 'deploy' did not dispatch drift_check.yml")
    if "Unknown command" in out:
        failures.append("menu selection produced 'Unknown command' (capture bug)")
    if failures:
        print("  FAIL menu selection regression")
        for f in failures:
            print(f"     - {f}")
        print("----- captured pty output -----")
        print(out[-2000:])
        return 1
    print("  ok   menu selection dispatches the chosen command cleanly")
    return 0


if __name__ == "__main__":
    sys.exit(main())
