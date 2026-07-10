#!/usr/bin/env python3
# Batch profiler for the UML "stall" blacklist. Runs each test to completion in
# its own UML probe (prof-init, 1800s internal timeout), samples the guest via
# mconsole sysrq-t, and classifies: PASS-slow / FAIL / HANG, fork-bound vs btrfs.
import os, sys, time, socket, struct, re, subprocess, json, collections

BASE="/home/prozak/uml-smoke"
KERNEL=f"{BASE}/linux-mainline/linux"
ROOTFS=f"{BASE}/rootfs-xfs"
TESTS=["btrfs/036","btrfs/050","generic/032","generic/037","generic/069",
       "generic/324","generic/371","generic/449","generic/615","generic/626",
       "generic/738","generic/748"]
MAXCONC=6
WALLCAP=1500          # seconds before we declare a real hang and kill
SAMPLE_EVERY=25       # sysrq sample cadence
OUT=f"{BASE}/results/stall-profile.json"
LOG=f"{BASE}/results/stall-profile.log"

def log(m):
    line=f"[{time.strftime('%H:%M:%S')}] {m}"
    print(line, flush=True)
    open(LOG,"a").write(line+"\n")

def mcon(sid, cmd):
    sock=os.path.expanduser(f"~/.uml/prof_{sid}/mconsole")
    if not os.path.exists(sock): return ""
    try:
        c=socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        c.bind("\0mc%d_%s_%d"%(os.getpid(), sid, int(time.time()*1000)%100000))
        c.settimeout(1.5)
        c.sendto(struct.pack("III",0xcafebabe,2,len(cmd))+cmd.encode(), sock)
        out=[]
        while True:
            try: r,_=c.recvfrom(8192)
            except socket.timeout: break
            err,more,ln=struct.unpack("III",r[:12]); out.append(r[12:12+ln].decode(errors='replace'))
            if not more: break
        c.close(); return "".join(out)
    except Exception: return ""

def sample(sid, acc):
    d=mcon(sid,"sysrq t")
    if not d: return
    acc["n"]+=1
    for blk in re.split(r'(?=task:)', d):
        m=re.match(r'task:(\S+)\s+state:(\S+)', blk)
        if not m: continue
        name,state=m.group(1),m.group(2)
        if 'xfs_io' in name: acc["xfsio"]+=1
        if re.search(r'btrfs_file_write|btrfs_buffered_write|btrfs_direct_write|iomap', blk): acc["btrfs_write"]+=1
        if re.search(r'send_|btrfs_ioctl_send|changed_cb', blk): acc["btrfs_send"]+=1
        if re.search(r'fsstress|fio\b', name): acc["stress"]+=1
        if state[0]=='D':                      # uninterruptible = real-hang signal
            acc["dstate"]+=1
            calls=[c for c in re.findall(r'\]\s+([\w.]+)\+0x', blk)
                   if c not in ('__switch_to','__schedule','schedule','io_schedule')]
            if calls: acc["dleaf"][calls[0]]+=1

def launch(i, test):
    sid=f"p{i}"
    d=f"{BASE}/shards/prof_{sid}"
    subprocess.run(["rm","-rf",d]); os.makedirs(f"{d}/results",exist_ok=True)
    open(f"{d}/RUN_ARGS","w").write(test+"\n")
    for img,sz in [("dummy.img","64M"),("test.img","3G"),("scratch.img","3G")]:
        subprocess.run(["truncate","-s",sz,f"{d}/{img}"])
    boot=open(f"{d}/boot.out","w")
    p=subprocess.Popen([KERNEL,"rootfstype=hostfs",f"rootflags={ROOTFS}","rw",
        "init=/prof-init.sh",f"shard=prof_{sid}",f"umid=prof_{sid}",
        f"ubda={d}/dummy.img",f"ubdb={d}/test.img",f"ubdc={d}/scratch.img",
        "seccomp=on","mem=2000M","con0=fd:0,fd:1","con=null"],
        stdout=boot, stderr=subprocess.STDOUT)
    return {"i":i,"sid":sid,"test":test,"dir":d,"proc":p,"t0":time.time(),
            "acc":collections.Counter({"dleaf":collections.Counter()}),
            "lastsample":0}

def classify(job):
    d=job["dir"]; test=job["test"]; acc=job["acc"]
    dur=None
    try: dur=int(open(f"{d}/results/duration").read().split("=")[1])
    except Exception: pass
    rl=""
    try: rl=open(f"{d}/results/run.log").read()
    except Exception: pass
    passed = "Passed all" in rl
    failed = ("Failures:" in rl) or ("[failed" in rl)
    notrun = ("not run" in rl and not passed and not failed)
    n=max(1,acc["n"])
    bottleneck=[]
    if acc["xfsio"]>0: bottleneck.append(f"xfs_io in {acc['xfsio']}/{acc['n']} samples")
    if acc["btrfs_write"]>0: bottleneck.append(f"btrfs_write x{acc['btrfs_write']}")
    if acc["btrfs_send"]>0: bottleneck.append(f"btrfs_send x{acc['btrfs_send']}")
    if acc["stress"]>0: bottleneck.append(f"fsstress/fio x{acc['stress']}")
    if acc["dstate"]>0: bottleneck.append(f"D-state x{acc['dstate']} leaves={dict(acc['dleaf'].most_common(4))}")
    return {"test":test,"outcome":job.get("outcome",
              "pass" if passed else "fail" if failed else "notrun" if notrun else "unknown"),
            "wall_s":round(time.time()-job["t0"]),"guest_dur_s":dur,
            "samples":acc["n"],"bottleneck":"; ".join(bottleneck) or "(no signal)"}

def main():
    open(LOG,"w").write("")
    log(f"batch: {len(TESTS)} tests, {MAXCONC} concurrent, wallcap={WALLCAP}s")
    todo=list(enumerate(TESTS)); active=[]; results=[]
    while todo or active:
        while todo and len(active)<MAXCONC:
            i,t=todo.pop(0); job=launch(i,t); active.append(job)
            log(f"launched {t} (prof_p{i})  [{len(active)} active, {len(todo)} queued]")
        time.sleep(3)
        for job in active[:]:
            now=time.time()
            if now-job["lastsample"]>=SAMPLE_EVERY:
                sample(job["sid"], job["acc"]); job["lastsample"]=now
            rc=job["proc"].poll()
            if rc is not None:                       # UML powered off = test done
                r=classify(job); results.append(r)
                log(f"DONE {job['test']}: {r['outcome']} guest_dur={r['guest_dur_s']}s | {r['bottleneck']}")
                active.remove(job)
            elif now-job["t0"]>WALLCAP:              # real hang
                sample(job["sid"], job["acc"])       # final snapshot of D-state
                job["outcome"]="HANG"
                subprocess.run(["pkill","-9","-f",f"umid=prof_{job['sid']}"])
                r=classify(job); r["outcome"]="HANG(killed@wallcap)"; results.append(r)
                log(f"HANG {job['test']}: killed @ {WALLCAP}s | {r['bottleneck']}")
                active.remove(job)
    json.dump(results, open(OUT,"w"), indent=2)
    log("=== BATCH COMPLETE ===")
    for r in sorted(results, key=lambda x:-(x['guest_dur_s'] or 9999)):
        log(f"  {r['test']:14s} {r['outcome']:22s} dur={str(r['guest_dur_s'])+'s':7s} {r['bottleneck']}")
    log(f"results -> {OUT}")

if __name__=="__main__": main()
