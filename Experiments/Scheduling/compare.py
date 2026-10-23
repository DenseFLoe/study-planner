#!/usr/bin/env python3
"""Synthetic, offline comparison. Never opens a production database or UI."""
import argparse
from fractions import Fraction
import hashlib
import itertools
import json
import math
from pathlib import Path
import platform
import subprocess
import tempfile
import time

import ortools
from ortools.sat.python import cp_model

ROOT = Path(__file__).resolve().parents[2]


def compile_adapter(directory):
    """Expose only the score oracle and capture its actual windows in temporary copies.

    Assert source anchors: a changed engine cannot silently run a stale adapter.
    Production sources and the application package manifest remain untouched.
    """
    core = ROOT / "Sources/StudyCore"
    sources = sorted(core.glob("*.swift")) + [Path(__file__).with_name("main.swift")]
    compiler = subprocess.check_output(["swiftc", "--version"])
    fingerprint = hashlib.sha256(compiler + b"-O -whole-module-optimization v1" + b"".join(p.read_bytes() for p in sources)).hexdigest()[:20]
    cache = ROOT / ".build/scheduling-experiment" / ("adapter-" + fingerprint)
    if cache.exists():
        return cache
    engine = (core / "ScheduleEngine.swift").read_text()
    anchor = "        let optimized = SchedulePreferenceOptimizer.optimize("
    assert engine.count(anchor) == 1
    capture = """        experimentDays = originalDays.map { day in
            .init(date: day.date, windows: day.free.map { .init(start: $0.start, end: $0.end) })
        }
"""
    (directory / "ScheduleEngine.swift").write_text(engine.replace(anchor, capture + anchor))
    optimizer = (core / "SchedulePreferenceOptimizer.swift").read_text()
    assert optimizer.count("private final class Search") == 1
    (directory / "SchedulePreferenceOptimizer.swift").write_text(optimizer.replace("private final class Search", "final class Search"))
    files = [p for p in sorted(core.glob("*.swift")) if p.name not in {"ScheduleEngine.swift", "SchedulePreferenceOptimizer.swift"}]
    binary = directory / "baseline"
    subprocess.run(["swiftc", "-O", "-whole-module-optimization", "-module-cache-path", str(directory / "modules"),
                    *map(str, files), str(directory / "ScheduleEngine.swift"),
                    str(directory / "SchedulePreferenceOptimizer.swift"),
                    str(Path(__file__).with_name("main.swift")), "-o", str(binary)], check=True)
    cache.parent.mkdir(parents=True, exist_ok=True)
    binary.replace(cache)
    return cache


def targets(f):
    result = []
    for c, course in enumerate(f["courses"]):
        work = [w["minutes"] for w in f["work"] if w["course"] == c]
        learnable = [d for d, windows in enumerate(f["scoreWindows"])
                     if course["start"] <= d * 1440 < course["end"]
                     and any(b - a >= min(work) for a, b in windows)] if work else []
        remaining = sum(work)
        target = Fraction(remaining) * Fraction(str(course["weight"])) / max(1, len(learnable))
        row = [Fraction(0)] * f["days"]
        for d in learnable:
            row[d] = min(remaining, target)
            remaining -= row[d]
        result.append(row)
    return result


def score(f, plan):
    """Independent exact rational translation, checked against Swift for every plan."""
    n, days = len(f["courses"]), f["days"]
    loads = [[0] * days for _ in range(n)]
    rows = [[] for _ in range(days)]
    for item in plan:
        rows[item["start"] // 1440].append(item)
    coverage = early_coverage = repetition = inversion = early = 0
    seen = [0] * n
    for d, row in enumerate(rows):
        row.sort(key=lambda r: r["start"])
        owners = []
        for item in row:
            w = f["work"][item["task"]]
            c, size = w["course"], w["minutes"]
            loads[c][d] += size
            owners.append(c)
            for other in range(n):
                inversion += seen[other] * size * max(0, f["courses"][c]["priority"] - f["courses"][other]["priority"])
            seen[c] += size
            early += item["start"] * size
        count = min(3, len(set(owners)))
        value = count * (count - 1) // 2
        coverage += value
        early_coverage += value * (days - d)
        if len(set(owners)) >= 2:
            repetition += sum(a == b for a, b in zip(owners, owners[1:]))
    desired = targets(f)
    boost = triple = Fraction(0)
    for c, course in enumerate(f["courses"]):
        if course["weight"] > 1:
            penalty = sum((loads[c][d] - desired[c][d]) ** 2 for d in range(days))
            boost += penalty
            if course["weight"] == 3:
                triple += penalty
    totals = [sum(row[d] for row in loads) for d in range(days)]
    values = {"diversity": [-coverage, -early_coverage, repetition], "dailyWeight": [boost],
              "coursePriority": [inversion], "balancedLoad": [sum(t*t for t in totals), sum(x*x for row in loads for x in row)]}
    return ([triple] if f["defaultOrder"] else []) + [v for rule in f["rules"] for v in values[rule]] + [early]


class Model:
    def __init__(self, f, fixed=None):
        self.f, self.m = f, cp_model.CpModel()
        m, work, courses = self.m, f["work"], f["courses"]
        self.starts, self.day, self.on_day = [], [], []
        physical = []
        horizon = f["days"] * 1440
        def domain(bounds, size):
            return [[a, b-size] for a, b in bounds if a + size <= b]
        for t, w in enumerate(work):
            c = courses[w["course"]]
            bounds = [[max(a, c["start"], f["floor"]), min(b, c["end"])] for a, b in f["windows"]]
            intervals = domain(bounds, w["minutes"])
            # Empty domain is explicitly inconsistent, never interpreted as UNKNOWN.
            s = m.new_int_var_from_domain(cp_model.Domain.from_intervals(intervals or [[0, 0]]), f"start{t}")
            if not intervals:
                m.add(0 == 1)
            if fixed is not None and t in fixed:
                m.add(s == fixed[t])
            if str(t) in f.get("locked", {}):
                m.add(s == f["locked"][str(t)])
            d = m.new_int_var(0, f["days"]-1, f"day{t}")
            m.add_division_equality(d, s, 1440)
            bits = []
            for k in range(f["days"]):
                bit = m.new_bool_var(f"on{t}_{k}")
                m.add(d == k).only_enforce_if(bit)
                m.add(d != k).only_enforce_if(bit.Not())
                bits.append(bit)
            self.starts.append(s); self.day.append(d); self.on_day.append(bits)
            physical.append(m.new_fixed_size_interval_var(s, w["minutes"], f"study{t}"))
        self.floats = []
        for i, e in enumerate(f["floating"]):
            bounds = [[max(a, e["start"]), min(b, e["end"])] for a, b in f["eventWindows"]]
            spans = domain(bounds, e["minutes"])
            s = m.new_int_var_from_domain(cp_model.Domain.from_intervals(spans or [[0, 0]]), f"float{i}")
            if not spans:
                m.add(0 == 1)
            self.floats.append(s)
            physical.append(m.new_fixed_size_interval_var(s, e["minutes"], f"event{i}"))
        m.add_no_overlap(physical)
        for c in range(len(courses)):
            queue = [t for t, w in enumerate(work) if w["course"] == c]
            for a, b in zip(queue, queue[1:]):
                m.add(self.starts[b] >= self.starts[a] + work[a]["minutes"] + 15)
        # One chronological circuit through all studies. Events may occupy the rest;
        # rest applies across windows/days, with no fictitious tail inside a window.
        arcs, same_arcs = [], []
        for i in range(len(work)):
            arcs.extend([(0, i+1, m.new_bool_var(f"first{i}")), (i+1, 0, m.new_bool_var(f"last{i}"))])
            for j in range(len(work)):
                if i == j:
                    continue
                if work[i]["course"] == work[j]["course"] and work[i]["rank"] >= work[j]["rank"]:
                    continue
                arc = m.new_bool_var(f"arc{i}_{j}")
                arcs.append((i+1, j+1, arc))
                m.add(self.starts[j] >= self.starts[i] + work[i]["minutes"] + 15).only_enforce_if(arc)
                if work[i]["course"] == work[j]["course"]:
                    same_arcs.append((i, j, arc))
        if work:
            m.add_circuit(arcs)
        maxwork = sum(w["minutes"] for w in work)
        loads, totals, mixed, coverage = [], [], [], []
        for c in range(len(courses)):
            row = []
            for d in range(f["days"]):
                load = m.new_int_var(0, maxwork, f"load{c}_{d}")
                m.add(load == sum(w["minutes"] * self.on_day[t][d] for t, w in enumerate(work) if w["course"] == c))
                row.append(load)
            loads.append(row)
        for d in range(f["days"]):
            present = []
            for c in range(len(courses)):
                bit = m.new_bool_var(f"present{c}_{d}")
                m.add(loads[c][d] > 0).only_enforce_if(bit)
                m.add(loads[c][d] == 0).only_enforce_if(bit.Not())
                present.append(bit)
            count = m.new_int_var(0, len(courses), f"count{d}")
            m.add(count == sum(present))
            cov = m.new_int_var(0, 3, f"coverage{d}")
            m.add_element(count, [min(3,k)*(min(3,k)-1)//2 for k in range(len(courses)+1)], cov)
            mix = m.new_bool_var(f"mixed{d}")
            m.add(count >= 2).only_enforce_if(mix)
            m.add(count <= 1).only_enforce_if(mix.Not())
            mixed.append(mix); coverage.append(cov)
            totals.append(sum(loads[c][d] for c in range(len(courses))))
        repetitions = []
        for i, j, arc in same_arcs:
            same_day = m.new_bool_var(f"sameDay{i}_{j}")
            m.add(self.day[i] == self.day[j]).only_enforce_if(same_day)
            m.add(self.day[i] != self.day[j]).only_enforce_if(same_day.Not())
            mix = m.new_bool_var(f"mixedAt{i}_{j}")
            m.add_element(self.day[i], mixed, mix)
            rep = m.new_bool_var(f"rep{i}_{j}")
            m.add_min_equality(rep, [arc, same_day, mix])
            repetitions.append(rep)
        inversion = []
        for i, a in enumerate(work):
            for j, b in enumerate(work):
                diff = courses[a["course"]]["priority"] - courses[b["course"]]["priority"]
                if diff <= 0:
                    continue
                before = m.new_bool_var(f"before{j}_{i}")
                m.add(self.starts[j] < self.starts[i]).only_enforce_if(before)
                m.add(self.starts[j] > self.starts[i]).only_enforce_if(before.Not())
                inversion.append(before * a["minutes"] * b["minutes"] * diff)
        def square(expr, bound, name):
            x = m.new_int_var(-bound, bound, name)
            m.add(x == expr)
            sq = m.new_int_var(0, bound*bound, name+"Sq")
            m.add_multiplication_equality(sq, [x, x])
            return sq
        desired = targets(f)
        scale = math.lcm(*(x.denominator for row in desired for x in row))
        assert maxwork * scale < 100_000_000, "Unsupported rational score size"
        boost, triple = [], []
        for c, course in enumerate(courses):
            if course["weight"] > 1:
                for d in range(f["days"]):
                    sq = square(loads[c][d]*scale - int(desired[c][d]*scale), maxwork*scale, f"boost{c}_{d}")
                    boost.append(sq)
                    if course["weight"] == 3:
                        triple.append(sq)
        values = {"diversity": [(-sum(coverage), 1), (-sum(v*(f["days"]-d) for d,v in enumerate(coverage)), 1), (sum(repetitions), 1)],
                  "dailyWeight": [(sum(boost), scale*scale)], "coursePriority": [(sum(inversion), 1)],
                  "balancedLoad": [(sum(square(t, maxwork, f"total{d}") for d,t in enumerate(totals)), 1),
                                   (sum(square(loads[c][d], maxwork, f"courseSq{c}_{d}") for c in range(len(courses)) for d in range(f["days"])), 1)]}
        self.objectives = ([(sum(triple), scale*scale)] if f["defaultOrder"] else []) + [x for rule in f["rules"] for x in values[rule]] + [(sum(s*w["minutes"] for s,w in zip(self.starts, work)), 1)]

    def plan(self, solver):
        return sorted([{"task": t, "start": solver.value(s)} for t,s in enumerate(self.starts)], key=lambda r:r["start"])


def solve(f, budget, fixed=None, hint=None, feasibility_only=False):
    begin = time.monotonic()
    model = Model(f, fixed)
    build_seconds = time.monotonic() - begin
    if hint:
        for row in hint:
            model.m.add_hint(model.starts[row["task"]], row["start"])
    phases, best, floats = [], None, None
    objectives = [(0, 1)] if feasibility_only else model.objectives
    for index, (expr, scale) in enumerate(objectives):
        remaining = budget - (time.monotonic() - begin)
        if remaining <= 0:
            phases.append({"index": index, "status": "UNKNOWN", "reason": "end-to-end budget exhausted before solve"})
            break
        model.m.minimize(expr)
        solver = cp_model.CpSolver()
        solver.parameters.num_search_workers = 1
        solver.parameters.random_seed = 20261023
        solver.parameters.max_time_in_seconds = remaining
        solver.parameters.relative_gap_limit = 0
        solver.parameters.absolute_gap_limit = 0
        status = solver.solve(model.m)
        phase = {"index": index, "status": solver.status_name(status), "solveSeconds": solver.wall_time}
        if status in (cp_model.OPTIMAL, cp_model.FEASIBLE):
            best = model.plan(solver)
            floats = [solver.value(s) for s in model.floats]
            value = solver.value(expr) if not isinstance(expr, int) else expr
            phase.update(value=value/scale, bound=solver.best_objective_bound/scale)
            # Cross-check every objective, including those not optimized yet.
            modeled = [Fraction(solver.value(e) if not isinstance(e, int) else e, k) for e,k in model.objectives]
            assert modeled == score(f, best), (f["name"], modeled, score(f,best))
            phases.append(phase)
            if status != cp_model.OPTIMAL:
                break  # Never trade an unproved higher level for a lower one.
            model.m.add(expr == value)
            model.m.clear_hints()
            for row in best:
                model.m.add_hint(model.starts[row["task"]], row["start"])
        else:
            phases.append(phase)
            if status == cp_model.MODEL_INVALID:
                raise RuntimeError(solver.solution_info())
            break
    proof = len(phases) == len(objectives) and all(p["status"] == "OPTIMAL" for p in phases)
    return {"plan": best, "floatingStarts": floats, "phases": phases, "allLevelsOptimal": proof and not feasibility_only,
            "status": "OPTIMAL" if proof else ("FEASIBLE" if best is not None else phases[-1]["status"]),
            "seconds": time.monotonic()-begin, "buildSeconds": build_seconds}


def validate(f, plan, floating=None, full=True):
    errors = []
    ids = [r["task"] for r in plan]
    if len(ids) != len(set(ids)) or (full and sorted(ids) != list(range(len(f["work"])))):
        errors.append("missing/duplicate work")
    for r in plan:
        w, s = f["work"][r["task"]], r["start"]
        c, end = f["courses"][w["course"]], s+w["minutes"]
        if str(r["task"]) in f.get("locked", {}) and s != f["locked"][str(r["task"])]:
            errors.append("locked placement")
        if not (s >= max(f["floor"], c["start"]) and end <= c["end"] and any(a <= s and end <= b for a,b in f["windows"])):
            errors.append("date/window/history")
    ordered = sorted(plan, key=lambda r:r["start"])
    for a,b in zip(ordered, ordered[1:]):
        if a["start"] + f["work"][a["task"]]["minutes"] + 15 > b["start"]:
            errors.append("study rest")
    for c in range(len(f["courses"])):
        ranks = [f["work"][r["task"]]["rank"] for r in ordered if f["work"][r["task"]]["course"] == c]
        if ranks != sorted(ranks):
            errors.append("lesson order")
    if floating is not None:
        if len(floating) != len(f["floating"]):
            errors.append("missing floating witness")
        spans = [(r["start"], r["start"]+f["work"][r["task"]]["minutes"]) for r in ordered]
        for start,e in zip(floating, f["floating"]):
            end = start+e["minutes"]
            if not (e["start"] <= start and end <= e["end"] and any(a <= start and end <= b for a,b in f["eventWindows"])):
                errors.append("floating window")
            if any(start < b and end > a for a,b in spans):
                errors.append("floating overlap")
            spans.append((start,end))
    return sorted(set(errors))


def metrics(f, plan):
    rows = [[r for r in sorted(plan,key=lambda r:r["start"]) if r["start"]//1440 == d] for d in range(f["days"])]
    owners = [[f["work"][r["task"]]["course"] for r in row] for row in rows]
    return {"score": [float(x) for x in score(f,plan)],
            "courseMinutes": [sum(f["work"][r["task"]]["minutes"] for r in plan if f["work"][r["task"]]["course"] == c) for c in range(len(f["courses"]))],
            "dailyMinutes": [sum(f["work"][r["task"]]["minutes"] for r in row) for row in rows],
            "mixedDays": sum(len(set(row)) >= 2 for row in owners), "threeSubjectDays": sum(len(set(row)) >= 3 for row in owners),
            "sameSubjectAdjacencies": sum(a==b for row in owners for a,b in zip(row,row[1:]))}


def lns(f, budget, baseline):
    begin = time.monotonic()
    best, history = baseline, []
    # Explicit destroy/repair: 2-day batches, then pairs of course queues.
    neighborhoods = [set(r["task"] for r in baseline if r["start"]//1440 in {d,d+1}) for d in range(f["days"]-1)]
    neighborhoods += [set(t for t,w in enumerate(f["work"]) if w["course"] in {c,(c+1)%len(f["courses"])}) for c in range(len(f["courses"]))]
    for freed in neighborhoods:
        remaining = budget-(time.monotonic()-begin)
        if remaining <= 0:
            break
        if not freed:
            continue
        fixed = {r["task"]:r["start"] for r in best if r["task"] not in freed}
        attempt = solve(f, min(remaining, max(.1,budget/3)), fixed=fixed, hint=best)
        improved = attempt["plan"] is not None and score(f,attempt["plan"]) < score(f,best)
        if improved:
            best = attempt["plan"]
        history.append({"freed":len(freed), "improved":improved, "status":attempt["status"], "seconds":attempt["seconds"]})
    return {"plan": best, "seconds":time.monotonic()-begin, "neighborhoods":history, "status":"FEASIBLE", "allLevelsOptimal":False}


def local_improvements(f, plan):
    """Exhaust actual single-relocate/two-swap neighborhoods with first-fit repacking."""
    if f["floating"]:
        return None
    rows = [[r["task"] for r in sorted(plan,key=lambda r:r["start"]) if r["start"]//1440 == d] for d in range(f["days"])]
    initial_score, count, improvements = score(f,plan), 0, 0
    def check(candidate):
        nonlocal count, improvements
        count += 1
        result, cursor = [], -10**9
        for d,row in enumerate(candidate):
            for t in row:
                size = f["work"][t]["minutes"]
                spans = f["scoreWindows"][d]
                found = next((max(cursor,a) for a,b in spans if max(cursor,a)+size <= b), None)
                if found is None:
                    return
                result.append({"task":t,"start":found}); cursor=found+size+15
        if not validate(f,result) and score(f,result)<initial_score:
            improvements += 1
    positions = [(d,i) for d,row in enumerate(rows) for i in range(len(row))]
    for a,i in positions:
        for b in range(f["days"]):
            for j in range(len(rows[b])+(a!=b)):
                cand = [row[:] for row in rows]
                t = cand[a].pop(i); cand[b].insert(j,t); check(cand)
    for (a,i),(b,j) in itertools.combinations(positions,2):
        cand = [row[:] for row in rows]
        cand[a][i],cand[b][j] = cand[b][j],cand[a][i]; check(cand)
    return {"attempts":count,"improvements":improvements}


def run(args):
    with tempfile.TemporaryDirectory(prefix="study-scheduler-") as temp:
        directory = Path(temp)
        binary = compile_adapter(directory)
        fixtures = json.loads(subprocess.check_output([binary],text=True))
        if args.case:
            fixtures = [f for f in fixtures if f["name"] in args.case]
            assert fixtures, "No matching cases"
        rows, oracle_requests = [], []
        for f in fixtures:
            budget = args.large_budget if len(f["work"]) > 30 else args.budget
            print(f"Running {f['name']} ({len(f['work'])} lessons, {budget}s cap)",flush=True)
            baseline = f["baseline"]
            full = len(baseline)==len(f["work"])
            errors = validate(f,baseline,full=False)
            assert not errors, (f["name"], errors)
            # Recover an explicit event-position witness for the production plan.
            witness = solve(f, budget, fixed={r["task"]:r["start"] for r in baseline}, feasibility_only=True) if f["floating"] and full else None
            if witness:
                assert witness["plan"] is not None, (f["name"],"baseline floating witness unavailable")
                assert not validate(f,baseline,witness["floatingStarts"])
            cp = solve(f,budget,hint=baseline if full else None)
            if cp["plan"] is not None:
                assert not validate(f,cp["plan"],cp["floatingStarts"])
                cp["metrics"] = metrics(f,cp["plan"])
                # Preserve baseline as incumbent if a time-limited solve regresses.
                cp["accepted"] = not full or score(f,cp["plan"]) <= score(f,baseline)
                cp["comparison"] = "completion" if not full else ("better" if score(f,cp["plan"])<score(f,baseline) else "equal" if score(f,cp["plan"])==score(f,baseline) else "worse-rejected")
            neighborhood = lns(f,budget,baseline) if full else None
            if neighborhood:
                assert not validate(f,neighborhood["plan"])
                neighborhood["metrics"]=metrics(f,neighborhood["plan"])
                # Validate floating witnesses for accepted LNS plans independently.
                if f["floating"]:
                    nw=solve(f,budget,fixed={r["task"]:r["start"] for r in neighborhood["plan"]},feasibility_only=True)
                    assert nw["plan"] is not None
                    assert not validate(f,neighborhood["plan"],nw["floatingStarts"])
                    neighborhood["floatingStarts"]=nw["floatingStarts"]
            row={"input":f,"baseline":{"metrics":metrics(f,baseline),"complete":full,"violations":errors,"floatingStarts":witness["floatingStarts"] if witness else None}, "cp":cp,"lns":neighborhood}
            if cp.get("comparison")=="better" and len(f["work"]) <= 15:
                row["localNeighborhood"]=local_improvements(f,baseline)
            rows.append(row)
            # Partial plans have a different production target amount: exclude their
            # scores from method comparisons and oracle equality claims.
            for plan in [baseline, cp["plan"], neighborhood["plan"] if neighborhood else None]:
                if plan is not None and len(plan)==len(f["work"]):
                    oracle_requests.append({"name":f["name"],"plan":plan})
        request_path=directory/"oracle.json"
        request_path.write_text(json.dumps(oracle_requests))
        oracle_scores=json.loads(subprocess.check_output([binary,request_path],text=True))
        assert len(oracle_scores) == len(oracle_requests)
        by_name={f["name"]:f for f in fixtures}
        for request,actual in zip(oracle_requests,oracle_scores):
            expected=score(by_name[request["name"]],request["plan"])
            assert len(expected)==len(actual) and all(abs(float(a)-b)<1e-5 for a,b in zip(expected,actual)), (request["name"],expected,actual)
        # Deliberately starved budget: UNKNOWN does not imply infeasibility.
        starved=solve(fixtures[-1],0)
        assert starved["status"]=="UNKNOWN"
        hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((ROOT/"Sources/StudyCore").glob("*.swift"))}
        output={"environment":{"ortools":ortools.__version__,"python":platform.python_version(),"machine":platform.machine(),"system":platform.platform(),"swift":subprocess.check_output(["swift","--version"],text=True).strip()},
                "budgets":{"smallSeconds":args.budget,"largeSeconds":args.large_budget,"includesModelBuild":True,"workers":1,"seed":20261023},
                "oracleChecks":len(oracle_scores),"sourceHashes":hashes,"starvedBudget":starved,"cases":rows}
        args.output.parent.mkdir(parents=True,exist_ok=True)
        args.output.write_text(json.dumps(output,ensure_ascii=False,indent=2)+"\n")
        print(f"Verified {len(rows)} cases and {len(oracle_scores)} production score comparisons. Results: {args.output}")


if __name__ == "__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--budget",type=float,default=3)
    parser.add_argument("--large-budget",type=float,default=8)
    parser.add_argument("--case",action="append")
    parser.add_argument("--output",type=Path,default=ROOT/".build/scheduling-experiment/results.json")
    run(parser.parse_args())
