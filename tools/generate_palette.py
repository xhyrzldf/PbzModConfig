"""Deterministic original HSV wheel for the runtime color editor; no game resources."""
import colorsys
import math
from pathlib import Path
import struct
import zlib


def generate(size=360):
    rows=[]
    for y in range(size):
        row=bytearray([0])
        for x in range(size):
            dx,dy=(x+.5-size/2)/(size/2),(size/2-y-.5)/(size/2)
            radius=math.hypot(dx,dy)
            rgb=colorsys.hsv_to_rgb((math.atan2(dy,dx)/math.tau)%1,min(1,radius),1)
            alpha=max(0,min(1,(1-radius)*size/2+.5))
            row.extend([*(round(v*255) for v in rgb),round(alpha*255)])
        rows.append(row)
    def chunk(kind,data):
        return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>2I5B',size,size,8,6,0,0,0))+chunk(b'sRGB',b'\x00')+chunk(b'IDAT',zlib.compress(b''.join(rows),9))+chunk(b'IEND',b'')


if __name__=='__main__':
    target=Path(__file__).resolve().parents[1]/'assets/color-wheel.png'
    target.write_bytes(generate())
    print(f'{target}: {target.stat().st_size} bytes')
