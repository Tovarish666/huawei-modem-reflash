#!/usr/bin/env python3
# dhcp-probe.py <интерфейс> - отправить DHCPDISCOVER и напечатать "<IP сервера> <предложенный IP> <маска>"
# Адрес на интерфейсе не меняет: нужен только чтобы узнать IP веб-интерфейса HiLink-модема.
import random, socket, struct, sys, time

ifc = sys.argv[1]
mac = bytes.fromhex(open(f"/sys/class/net/{ifc}/address").read().strip().replace(":", ""))
xid = random.randint(0, 2**32 - 1)
pkt = struct.pack("!BBBBIHH4s4s4s4s16s64s128s", 1, 1, 6, 0, xid, 0, 0x8000,
                  b"\0" * 4, b"\0" * 4, b"\0" * 4, b"\0" * 4, mac + b"\0" * 10, b"\0" * 64, b"\0" * 128)
pkt += b"\x63\x82\x53\x63" + b"\x35\x01\x01" + b"\x37\x03\x01\x03\x06" + b"\xff"

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, ifc.encode())
s.bind(("", 68))
s.settimeout(2)

for attempt in range(5):
    s.sendto(pkt, ("255.255.255.255", 67))
    end = time.time() + 3
    while time.time() < end:
        try:
            data, addr = s.recvfrom(2048)
        except socket.timeout:
            break
        if len(data) < 240 or struct.unpack("!I", data[4:8])[0] != xid:
            continue
        yiaddr = socket.inet_ntoa(data[16:20])
        opts, i, info = data[240:], 0, {}
        while i < len(opts) and opts[i] != 255:
            if opts[i] == 0:
                i += 1
                continue
            t, l = opts[i], opts[i + 1]
            info[t] = opts[i + 2:i + 2 + l]
            i += 2 + l
        srv = socket.inet_ntoa(info[54]) if 54 in info else addr[0]
        mask = socket.inet_ntoa(info[1]) if 1 in info else "255.255.255.0"
        print(srv, yiaddr, mask)
        sys.exit(0)
sys.exit(1)
