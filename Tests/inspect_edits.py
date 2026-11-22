#!/usr/bin/env python3
"""inspect_edits.py <file>...: each track's handler, edit list (elst) and
track / media durations, read straight from the file's boxes."""
import struct
import sys


def boxes(data, start, end):
    pos = start
    while pos + 8 <= end:
        size, kind = struct.unpack(">I4s", data[pos:pos + 8])
        header = 8
        if size == 1:
            size = struct.unpack(">Q", data[pos + 8:pos + 16])[0]
            header = 16
        elif size == 0:
            size = end - pos
        if size < header:
            return
        yield kind.decode("latin1"), pos, header, size
        pos += size


def main():
    for path in sys.argv[1:]:
        data = open(path, "rb").read()
        print(f"== {path}")
        top = {kind: (pos, header, size) for kind, pos, header, size in boxes(data, 0, len(data))}
        if "moov" not in top:
            print("  no moov")
            continue
        mpos, mheader, msize = top["moov"]
        for kind, pos, header, size in boxes(data, mpos + mheader, mpos + msize):
            if kind != "trak":
                continue
            handler, edits, media = "?", [], ""
            for kind2, pos2, header2, size2 in boxes(data, pos + header, pos + size):
                if kind2 == "edts":
                    for kind3, pos3, header3, size3 in boxes(data, pos2 + header2, pos2 + size2):
                        if kind3 == "elst":
                            body = pos3 + header3
                            version = data[body]
                            count = struct.unpack(">I", data[body + 4:body + 8])[0]
                            for k in range(count):
                                if version == 0:
                                    edits.append(struct.unpack(">Ii", data[body + 8 + k * 12:body + 16 + k * 12]))
                                else:
                                    edits.append(struct.unpack(">Qq", data[body + 8 + k * 20:body + 24 + k * 20]))
                if kind2 == "mdia":
                    for kind3, pos3, header3, size3 in boxes(data, pos2 + header2, pos2 + size2):
                        if kind3 == "hdlr":
                            handler = data[pos3 + header3 + 8:pos3 + header3 + 12].decode("latin1")
                        if kind3 == "mdhd":
                            body = pos3 + header3
                            if data[body] == 0:
                                scale, duration = struct.unpack(">II", data[body + 12:body + 20])
                            else:
                                scale, duration = struct.unpack(">IQ", data[body + 20:body + 32])
                            media = f"media {duration}/{scale}"
            print(f"  {handler}: {media}; edit list (duration in movie scale, media start): {edits or 'none'}")


if __name__ == "__main__":
    main()
