#!/usr/bin/env python3
"""Convert a flat binary (objcopy -O binary) into a word-addressed $readmemh file."""
import sys, struct

bin_path, hex_path, base = sys.argv[1], sys.argv[2], int(sys.argv[3], 0)
data = open(bin_path, "rb").read()

# pad up to a word boundary
if len(data) % 4:
    data += b"\x00" * (4 - len(data) % 4)

words = list(struct.unpack("<%dI" % (len(data) // 4), data))
base_words = base // 4

out = []
out.extend(["00000013"] * (base_words & 0xF))  # honour %x semantics below
# emulate $readmemh: lines are consumed from index 0
lines = ["00000013"] * base_words
lines += ["%08x" % w for w in words]
open(hex_path, "w").write("\n".join(lines) + "\n")
print("wrote %s: %d words (base 0x%x)" % (hex_path, len(lines), base))
