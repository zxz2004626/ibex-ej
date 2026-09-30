import subprocess, os, sys

GOLD = dict(l.split() for l in open("golden.txt"))
HDIV_OK, HREM_OK = "fdb6db6e", "fffffffe"   # -268435456 / 7, % 7
UNINIT = "00000013"                          # memory fill pattern = handler never ran
BAD = []

def run(start, ln, mode):
    d = "s_%d_%d_%d.txt" % (start, ln, mode)
    if os.path.exists(d): os.remove(d)
    subprocess.run(["./simv", "+mem=prog.hex", "+dump="+d, "+irq_start=%d" % start,
                    "+irq_len=%d" % ln, "+irq_mode=%d" % mode, "+max_cycles=20000",
                    "-l", "s.log"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if not os.path.exists(d): return None
    return dict(l.split() for l in open(d))

n = 0
for mode, ln in ((1, 1), (1, 7), (0, 1), (0, 3), (0, 40)):
    for start in range(5, 205):
        r = run(start, ln, mode); n += 1
        if r is None:
            BAD.append((start, ln, mode, ["NO DUMP"])); continue
        p = []
        for k in ("div1", "rem1", "mul", "mulh", "div2", "rem2"):
            if r.get(k) != GOLD[k]: p.append("%s=%s want %s" % (k, r.get(k), GOLD[k]))
        hd, hr = r.get("hdiv"), r.get("hrem")
        if (hd, hr) not in ((UNINIT, UNINIT), (HDIV_OK, HREM_OK)):
            p.append("HANDLER CORRUPT hdiv=%s hrem=%s" % (hd, hr))
        if p: BAD.append((start, ln, mode, p))

print("runs=%d  failures=%d" % (n, len(BAD)))
for b in BAD[:30]: print("  ", b)
if not BAD: print("ALL PASS")
