#!/usr/bin/env python3
from __future__ import annotations

import argparse, csv, json, math, os, platform, statistics, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent
ALLOWED = {"schema_version","id","series","tier","family","operation","fixture","settings","warmups","samples","timeout_seconds"}
FAMILIES = {"tree_tidy","tree_radial","layered","circular","force","stress","radial","constrained","overlap","pack","compound","route","metrics_crossings","metrics_bends"}

class Failure(Exception): pass

def load_cases(path: Path):
    cases=[]; ids=set()
    for number,line in enumerate(path.read_text().splitlines(),1):
        if not line.strip(): continue
        case=json.loads(line); unknown=set(case)-ALLOWED
        if unknown: raise Failure(f"{path}:{number}: unknown fields {sorted(unknown)}")
        missing=ALLOWED-set(case)
        if missing: raise Failure(f"{path}:{number}: missing fields {sorted(missing)}")
        if case["schema_version"] != 1 or case["family"] not in FAMILIES: raise Failure(f"{path}:{number}: unsupported schema/family")
        if case["id"] in ids: raise Failure(f"{path}:{number}: duplicate id {case['id']}")
        ids.add(case["id"]); fixture=case["fixture"]
        if set(fixture)!={"source","name","size","seed","parameters"} or fixture["source"] not in {"generated","embedded"}: raise Failure(f"{path}:{number}: invalid fixture")
        if case["settings"] or fixture["parameters"]: raise Failure(f"{path}:{number}: settings/parameters are reserved for schema v2")
        cases.append(case)
    return cases

def run(cmd, cwd=REPO, timeout=None):
    return subprocess.run(cmd,cwd=cwd,text=True,capture_output=True,timeout=timeout,check=False)

def compiler():
    return os.environ.get("ROC", "roc")

def build(binary: Path):
    z=run(["zig","build","-Doptimize=ReleaseFast"],ROOT/"platform")
    if z.returncode: raise Failure(z.stdout+z.stderr)
    binary.parent.mkdir(parents=True,exist_ok=True)
    r=run([compiler(),"build","main.roc",f"--output={binary}","--opt=speed","--no-cache"],ROOT,180)
    if r.returncode: raise Failure(r.stdout+r.stderr)

def sample(binary: Path, case: dict, index: int):
    f=case["fixture"]
    cmd=[str(binary),case["family"],case["operation"],f["source"],f["name"],str(f["size"]),str(f["seed"])]
    try: p=run(cmd,ROOT,float(case["timeout_seconds"]))
    except subprocess.TimeoutExpired: return {"case_id":case["id"],"sample":index,"status":"timeout"}
    if p.returncode: return {"case_id":case["id"],"sample":index,"status":"error","exit_code":p.returncode,"stderr":p.stderr[-2000:]}
    try: measured=json.loads(p.stdout.strip().splitlines()[-1])
    except Exception as e: return {"case_id":case["id"],"sample":index,"status":"malformed","detail":str(e),"stdout":p.stdout[-2000:]}
    # The Roc app's observation is deliberately computed from the complete
    # result shape after the timed operation; expose it under the stable digest
    # field used by comparisons as well as its descriptive name.
    measured["digest"] = measured["observation"]
    measured.update({"case_id":case["id"],"series":case["series"],"tier":case["tier"],"sample":index,"status":"ok"})
    return measured

def metadata():
    version=run([compiler(),"version"]).stdout.strip(); zig=run(["zig","version"]).stdout.strip()
    revision=run(["git","rev-parse","HEAD"]).stdout.strip(); dirty=bool(run(["git","status","--porcelain"]).stdout)
    return {"roc_version":version,"zig_version":zig,"os":platform.system().lower(),"arch":platform.machine(),"revision":revision,"dirty":dirty,"opt":"speed"}

def summarize(rows, outdir: Path):
    ok=[r for r in rows if r["status"]=="ok"]
    fields=["case_id","family","operation","fixture","n","m","samples","median_ns","min_ns","median_peak_extra_bytes","median_bytes_requested","growth_ratio","empirical_exponent"]
    summaries=[]
    for cid in sorted({r["case_id"] for r in ok}):
        group=[r for r in ok if r["case_id"]==cid]; first=group[0]
        summaries.append({"case_id":cid,"family":first["family"],"operation":first["operation"],"fixture":first["fixture"],"n":first["n"],"m":first["m"],"samples":len(group),"median_ns":int(statistics.median(r["elapsed_ns"] for r in group)),"min_ns":min(r["elapsed_ns"] for r in group),"median_peak_extra_bytes":int(statistics.median(r["peak_extra_bytes"] for r in group)),"median_bytes_requested":int(statistics.median(r["bytes_requested"] for r in group)),"growth_ratio":"","empirical_exponent":""})
    for series in {r["series"] for r in ok}:
        ordered=sorted([s for s in summaries if next(r for r in ok if r["case_id"]==s["case_id"])["series"]==series],key=lambda x:x["n"])
        for a,b in zip(ordered,ordered[1:]):
            ratio=b["median_ns"]/max(a["median_ns"],1); size=b["n"]/max(a["n"],1)
            b["growth_ratio"]=f"{ratio:.3f}"; b["empirical_exponent"]=f"{math.log(ratio,size):.3f}" if size>1 and ratio>0 else ""
    with (outdir/"summary.csv").open("w",newline="") as fh:
        w=csv.DictWriter(fh,fieldnames=fields); w.writeheader(); w.writerows(summaries)
    lines=["# Benchmark summary","","| Case | n | median ms | peak extra MiB | growth | exponent |","|---|---:|---:|---:|---:|---:|"]
    for s in summaries: lines.append(f"| {s['case_id']} | {s['n']} | {s['median_ns']/1e6:.3f} | {s['median_peak_extra_bytes']/1048576:.3f} | {s['growth_ratio']} | {s['empirical_exponent']} |")
    (outdir/"summary.md").write_text("\n".join(lines)+"\n")

def execute(tier: str, output: Path):
    cases=load_cases(ROOT/"cases"/f"{tier}.jsonl"); binary=ROOT/".cache"/"layout-bench"; build(binary); meta=metadata(); rows=[]; stopped=set()
    for case in cases:
        if case["series"] in stopped: rows.append({"case_id":case["id"],"series":case["series"],"status":"skipped_after_failure",**meta}); continue
        for i in range(case["warmups"]):
            warm=sample(binary,case,-i-1)
            if warm["status"]!="ok": raise Failure(f"warmup failed: {warm}")
        case_rows=[sample(binary,case,i) for i in range(case["samples"])]
        for row in case_rows: row.update(meta)
        rows.extend(case_rows)
        if any(r["status"] in {"timeout","error"} for r in case_rows): stopped.add(case["series"])
        print(f"{case['id']}: {', '.join(r['status'] for r in case_rows)}")
    output.mkdir(parents=True,exist_ok=True)
    with (output/"samples.jsonl").open("w") as fh:
        for row in rows: fh.write(json.dumps(row,sort_keys=True)+"\n")
    summarize(rows,output)
    if tier=="smoke":
        for case in cases:
            group=[r for r in rows if r.get("case_id")==case["id"]]
            if not group or any(r["status"]!="ok" for r in group): raise Failure(f"smoke failure: {case['id']}")
            stable=("observation","alloc_calls","realloc_calls","dealloc_calls","bytes_requested","bytes_released","peak_extra_bytes")
            if any(tuple(r[k] for k in stable)!=tuple(group[0][k] for k in stable) for r in group[1:]): raise Failure(f"nondeterministic telemetry: {case['id']}")

def compare(a: Path,b: Path):
    def read(p): return {r["case_id"]:r for r in map(json.loads,p.read_text().splitlines()) if r.get("status")=="ok"}
    left,right=read(a),read(b)
    for cid in sorted(left.keys()&right.keys()):
        x,y=left[cid],right[cid]; compatible=all(x.get(k)==y.get(k) for k in ("os","arch","roc_version","opt"))
        print(f"{cid}: " + (f"time {100*(y['elapsed_ns']/x['elapsed_ns']-1):+.1f}%, requested {100*(y['bytes_requested']/max(x['bytes_requested'],1)-1):+.1f}%" if compatible else "incompatible environments"))

def main():
    p=argparse.ArgumentParser(); sub=p.add_subparsers(dest="cmd",required=True)
    for name in ("smoke","scale"):
        q=sub.add_parser(name); q.add_argument("--output",type=Path,default=ROOT/"results"/name)
    q=sub.add_parser("compare"); q.add_argument("baseline",type=Path); q.add_argument("candidate",type=Path)
    a=p.parse_args(); compare(a.baseline,a.candidate) if a.cmd=="compare" else execute(a.cmd,a.output)

if __name__=="__main__":
    try: main()
    except (Failure,OSError,json.JSONDecodeError) as e: raise SystemExit(str(e)) from None
