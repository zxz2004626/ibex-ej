import subprocess, os, sys
BIN=sys.argv[1]
GOLD=dict(l.split() for l in open("golden.txt"))
HDIV_OK, HREM_OK = "fdb6db6e", "fffffffe"
UNINIT="00000013"
BAD=[]; ran=0; n=0
for mode,ln in ((1,1),(1,7),(0,1),(0,3),(0,40)):
    for start in range(5,205):
        d="z_%d_%d_%d.txt"%(start,ln,mode)
        if os.path.exists(d): os.remove(d)
        subprocess.run([BIN,"+mem=prog.hex","+dump="+d,"+irq_start=%d"%start,
                        "+irq_len=%d"%ln,"+irq_mode=%d"%mode,"+max_cycles=20000",
                        "-l","z.log"],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        n+=1
        if not os.path.exists(d): BAD.append((start,ln,mode,["NO DUMP"])); continue
        r=dict(l.split() for l in open(d))
        p=[]
        for k in ("div1","rem1","mul","mulh","div2","rem2"):
            if r.get(k)!=GOLD[k]: p.append("%s=%s want %s"%(k,r.get(k),GOLD[k]))
        if r.get("hdiv")==HDIV_OK: ran+=1
        if (r.get("hdiv"),r.get("hrem")) not in ((UNINIT,UNINIT),(HDIV_OK,HREM_OK)):
            p.append("HANDLER CORRUPT hdiv=%s hrem=%s"%(r.get("hdiv"),r.get("hrem")))
        if p: BAD.append((start,ln,mode,p))
print("%s: runs=%d handler_ran=%d failures=%d"%(os.path.basename(BIN),n,ran,len(BAD)))
for b in BAD[:20]: print("   ",b)
if not BAD: print("   ALL PASS")
