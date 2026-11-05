"""Render the neutral installation background without external dependencies."""
from pathlib import Path
import binascii
import struct
import sys
import zlib

width, height = 540, 320
pixels = bytearray([236] * width * height * 3)
points = [(245, 200), (265, 200), (265, 181), (290, 210),
          (265, 239), (265, 220), (245, 220), (245, 200)]
distance = 0
for (x0, y0), (x1, y1) in zip(points, points[1:]):
    steps = max(abs(x1 - x0), abs(y1 - y0))
    for step in range(steps):
        x = round(x0 + (x1 - x0) * step / steps)
        y = round(y0 + (y1 - y0) * step / steps)
        if distance % 7 < 4:
            offset = (y * width + x) * 3
            pixels[offset:offset + 3] = bytes([120, 120, 120])
        distance += 1

def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', binascii.crc32(kind + data) & 0xffffffff)

rows = b''.join(b'\x00' + pixels[y * width * 3:(y + 1) * width * 3] for y in range(height))
png = b'\x89PNG\r\n\x1a\n'
png += chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
png += chunk(b'IDAT', zlib.compress(rows))
png += chunk(b'IEND', b'')
Path(sys.argv[1]).write_bytes(png)
