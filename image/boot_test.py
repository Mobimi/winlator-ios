#!/usr/bin/env python3
import os
import re
import subprocess
import sys
import time

import pexpect

IMAGE = sys.argv[1] if len(sys.argv) > 1 else "img"
SHARE = os.path.abspath(os.path.join(IMAGE, "share"))
os.makedirs(SHARE, exist_ok=True)
START = time.time()


def stamp():
    return "%6.1fs" % (time.time() - START)


def say(message):
    print("[%s] %s" % (stamp(), message), flush=True)

args = [
    "qemu-system-aarch64",
    "-M", "virt,highmem=on",
    "-cpu", "max",
    "-smp", "3",
    "-m", "1792",
    "-accel", "tcg,thread=multi,tb-size=256",
    "-rtc", "base=utc,clock=host",
    "-kernel", os.path.join(IMAGE, "vmlinuz"),
    "-initrd", os.path.join(IMAGE, "initrd.img"),
    "-append", "console=ttyAMA0 root=/dev/vda rw loglevel=4 net.ifnames=0",
    "-drive", "if=virtio,format=raw,cache=writeback,file=" + os.path.join(IMAGE, "rootfs.ext4"),
    "-virtfs", "local,path=%s,mount_tag=share,security_model=none,multidevs=remap" % SHARE,
    "-netdev", "user,id=n0,hostfwd=tcp:127.0.0.1:5173-:5173",
    "-device", "virtio-net-pci,netdev=n0",
    "-object", "rng-random,filename=/dev/urandom,id=rng0",
    "-device", "virtio-rng-pci,rng=rng0",
    "-display", "none",
    "-nodefaults",
    "-no-user-config",
    "-serial", "mon:stdio",
    "-name", "devbox-test",
]

child = pexpect.spawn(args[0], args[1:], timeout=900, encoding="utf-8", codec_errors="replace", logfile=sys.stdout)
failures = []


def fail(message):
    failures.append(message)
    print("\nFAIL: " + message, flush=True)


def sync(timeout=60):
    child.sendline("echo SYNC-$((3+3))")
    child.expect("SYNC-6", timeout=timeout)


def run(cmd, pattern, timeout=180):
    sync()
    child.sendline(cmd)
    try:
        child.expect(pattern, timeout=timeout)
    except pexpect.TIMEOUT:
        fail("timeout waiting for %r after: %s" % (pattern, cmd))


try:
    child.expect(r"dev@devbox.*\$", timeout=900)
    say("login prompt")
    child.sendline("echo READY-$((1+1))")
    child.expect("READY-2", timeout=60)

    run("python3 -V", r"Python 3\.13\.\d+")
    run("node -v", r"v22\.\d+\.\d+")
    run("npm -v", r"\d+\.\d+\.\d+")
    run("git --version", r"git version 2\.")
    run("gcc --version", r"gcc \(Debian")
    run("mountpoint /mnt/share", r"is a mountpoint")
    run("df -h / | tail -n1", r"/dev/vda")
    run("ip -4 -o addr show eth0", r"inet 10\.0\.2\.15")
    run("python3 -c \"import urllib.request; print('NET', urllib.request.urlopen('https://pypi.org/simple/', timeout=20).status)\"", r"NET 200", timeout=120)

    child.sendline("cd /home/dev/projects && python3 -m http.server 5173 >/tmp/http.log 2>&1 &")
    time.sleep(5)
    sync()

    ports_file = os.path.join(SHARE, ".ports")
    ports = ""
    if os.path.exists(ports_file):
        ports = open(ports_file).read()
    if "5173" not in ports.split():
        fail("portwatch did not publish 5173, .ports=%r" % ports)
    else:
        say("portwatch published 5173")

    curl = subprocess.run(["curl", "-fsS", "--max-time", "10", "http://127.0.0.1:5173/"], capture_output=True, text=True)
    if curl.returncode != 0 or "Directory listing" not in curl.stdout:
        fail("hostfwd/HTTP failed rc=%s out=%r err=%r" % (curl.returncode, curl.stdout[:200], curl.stderr[:200]))
    else:
        say("hostfwd HTTP responded")

    child.sendline("kill $(pgrep -f 'http[.]server 5173' | head -n1)")
    sync()
    sync()
    child.sendline("sudo systemctl poweroff")
    child.expect(pexpect.EOF, timeout=180)
    say("clean poweroff")
except pexpect.EOF:
    fail("QEMU exited early")
except pexpect.TIMEOUT:
    fail("boot timed out")
except Exception as exc:
    fail("unexpected: %r" % exc)
finally:
    if child.isalive():
        child.terminate(force=True)

if failures:
    print("\n%d check(s) failed" % len(failures), flush=True)
    sys.exit(1)
print("\nall checks passed", flush=True)
