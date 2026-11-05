#!/usr/bin/env python3
"""A stand-in network receipt / kitchen printer for local tests (LOCAL ONLY).

Real thermal printers on a shop's Wi-Fi take raw ESC/POS bytes on TCP port 9100. This listens the same way, saves every job as
<out>/<n>-<port>.bin, writes a readable copy (<n>-<port>.txt: printable text, line feeds kept, control codes dropped, "--- CUT ---" at
a paper cut) and prints one line per job. Run one per printer you set up in Devices, e.g. a kitchen printer and a bill printer:

    python3 tool/fake_printer.py --port 9100 --out /tmp/printjobs &
    python3 tool/fake_printer.py --port 9101 --out /tmp/printjobs &

then in Devices add a LAN printer with address 127.0.0.1:9100 (a simulator or this Mac) or <this Mac's Wi-Fi IP>:9100 (a phone).
"""
import argparse
import os
import socket
import threading

CUT = (b'\x1dV', b'\x1bi', b'\x1bm')


def readable(data: bytes) -> str:
    out, i = [], 0
    while i < len(data):
        b = data[i]
        if data[i:i + 2] in CUT:
            out.append('\n--- CUT ---\n')
            i += 3
            continue
        if b == 0x1b or b == 0x1d:  # ESC / GS command: skip the command byte and its usual one argument
            i += 3 if data[i + 1:i + 2] in (b'!', b'E', b'a', b'd', b'-', b'M', b'V', b'B', b'h', b'w') else 2
            continue
        if b == 0x0a:
            out.append('\n')
        elif 0x20 <= b < 0x7f or b >= 0xa0:
            out.append(chr(b))
        i += 1
    return ''.join(out)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', type=int, default=9100)
    ap.add_argument('--host', default='0.0.0.0')
    ap.add_argument('--out', default='/tmp/printjobs')
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    count = [len([f for f in os.listdir(a.out) if f.endswith('.bin')])]
    lock = threading.Lock()

    def job(conn: socket.socket) -> None:
        conn.settimeout(5)
        chunks = []
        try:
            while True:
                c = conn.recv(65536)
                if not c:
                    break
                chunks.append(c)
        except socket.timeout:
            pass
        finally:
            conn.close()
        data = b''.join(chunks)
        if not data:
            return
        with lock:
            count[0] += 1
            n = count[0]
        base = os.path.join(a.out, f'{n:04d}-{a.port}')
        open(base + '.bin', 'wb').write(data)
        text = readable(data)
        open(base + '.txt', 'w').write(text)
        first = next((l.strip() for l in text.splitlines() if l.strip()), '')
        print(f'[fake printer :{a.port}] job {n}: {len(data)} bytes, first line "{first[:60]}" -> {base}.txt', flush=True)

    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((a.host, a.port))
    s.listen(8)
    print(f'[fake printer :{a.port}] listening on {a.host}:{a.port}, jobs in {a.out}', flush=True)
    while True:
        conn, _ = s.accept()
        threading.Thread(target=job, args=(conn,), daemon=True).start()


if __name__ == '__main__':
    main()
