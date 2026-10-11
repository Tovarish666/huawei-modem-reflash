#!/usr/bin/env python3
# at.py <tty> <команда> [таймаут_сек] - отправить AT-команду в порт модема и напечатать ответ
import os, select, sys, termios, time

tty, cmd = sys.argv[1], sys.argv[2]
tmo = float(sys.argv[3]) if len(sys.argv) > 3 else 3

fd = os.open(tty, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
a = termios.tcgetattr(fd)
a[0] = 0
a[1] = 0
a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
a[3] = 0
a[4] = a[5] = termios.B115200
termios.tcsetattr(fd, termios.TCSANOW, a)
termios.tcflush(fd, termios.TCIOFLUSH)

os.write(fd, (cmd + "\r").encode())
out = b""
t = time.time()
while time.time() - t < tmo:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try:
            out += os.read(fd, 4096)
        except (BlockingIOError, OSError):
            break
    if b"OK\r" in out or b"ERROR" in out:
        break
os.close(fd)
print(out.decode(errors="replace").replace("\r", "").strip())
