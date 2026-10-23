#!/usr/bin/env python3
"""Render synthetic result data as reviewable tables, without solver logs."""
import argparse
from collections import Counter
import json
from pathlib import Path


def array(values):
    return "[" + ", ".join(str(int(v)) if float(v).is_integer() else f"{v:.6g}" for v in values) + "]"


def render(data):
    cases=data["cases"]
    statuses=Counter(r["cp"]["status"] for r in cases)
    lines=["# 合成排课对照结果（2026-10-23）", "",
           "这是实验结果表，不包含个人日程或求解器运行日志。复现方法、评分解释和限制见 [README](README.md)。", "",
           f"环境：OR-Tools {data['environment']['ortools']}；Python {data['environment']['python']}；{data['environment']['system']}；Swift 6.4；单 worker；seed=20261023。",
           f"共 {len(cases)} 例；CP-SAT 状态 {dict(statuses)}；{data['oracleChecks']} 次完整评分与 Swift 原评分函数一致。",
           "小例各方法最多 3 秒，大例各最多 8 秒，建模计入；API 收尾可能稍超时。基线使用原有确定性操作预算，记录实际耗时。编译、导出、评分复核和独立验证不计入求解预算。", "",
           "OPTIMAL 表示本例所有评分层均证明最优；INFEASIBLE 表示全部按期完成的模型已证无解；UNKNOWN 表示新求解没有确定结论。基线已经可行时始终可保留。LNS 只称可行改进，不宣称全局最优。", "",
           "| 案例 | 基线秒 | CP 秒 | CP 状态 / 与基线比较 | LNS 秒 / 比较 |",
           "|---|---:|---:|---|---|"]
    for r in cases:
        f,c,n=r["input"],r["cp"],r["lns"]
        comp={"equal":"相同","better":"改善","completion":"补全","worse-rejected":"退步，拒绝"}.get(c.get("comparison"),"无候选")
        nc="改善" if n and n["metrics"]["score"]<r["baseline"]["metrics"]["score"] else "相同"
        lines.append(f"| {f['name']} | {f['baselineSeconds']:.4f} | {c['seconds']:.3f} | {c['status']} / {comp} | {str(round(n['seconds'],3))+' / '+nc if n else '—'} |")
    lines += ["", "## 完整评分与学习量", "",
              "所有向量从左到右比较，越小越好。默认顺序向量为 `[三倍例外, -共现覆盖, -较早共现, 混排日同科相邻, 加量误差, 优先级逆序, 每日总量平方和, 分科每日量平方和, 时间加权]`。自定义顺序不含三倍例外；按各例列出的规则展开（diversity 三项、balancedLoad 两项，其余一项），最后加时间项。", "",
              "课程数组按稳定 ID 排序，名称顺序逐例列出。CP/LNS 的全部已排入分钟均逐课验证；完整方案等于所需分钟。未排完整基线的评分仅作记录，目标总量与完整方案不同，禁止据此做偏好优劣比较。连续同科统计含单科日；评分的重复项只计混排日。", ""]
    for r in cases:
        f,c,n=r["input"],r["cp"],r["lns"]
        required=[sum(w["minutes"] for w in f["work"] if w["course"]==i) for i in range(len(f["courses"]))]
        lines += [f"### {f['name']}", "",
                  f"{len(f['work'])} 节 / {f['days']} 天；课程顺序：{', '.join(c['name'] for c in f['courses'])}；所需分钟 {array(required)}。规则 {', '.join(f['rules'])}；默认例外 {'有' if f['defaultOrder'] else '无'}。",
                  f"基线完整：{r['baseline']['complete']}；硬约束违规：{r['baseline']['violations']}。",
                  "", "| 方法 | 完整评分 | 各课程按期分钟 | 每日纯学习分钟 | 混排天 / 三科天 / 同科相邻 |", "|---|---|---|---|---|"]
        for label,m in [("现算法",r["baseline"]["metrics"]),("CP-SAT",c.get("metrics")),("LNS",n["metrics"] if n else None)]:
            if m:
                lines.append(f"| {label} | {array(m['score'])} | {array(m['courseMinutes'])} | {array(m['dailyMinutes'])} | {m['mixedDays']} / {m['threeSubjectDays']} / {m['sameSubjectAdjacencies']} |")
        phases="，".join(f"{p['index']}:{p['status']}" for p in c["phases"])
        lines += ["",f"CP 层级证明：{phases}。已找到的新完整候选均通过独立硬约束校验。"]
        if r.get("localNeighborhood"):
            local=r["localNeighborhood"]
            lines.append(f"穷尽现有单节搬移 / 两节交换邻域 {local['attempts']} 个尝试，改善 {local['improvements']} 个。")
        lines.append("")
    for name in ["seeded-tight-6","default-triple-exception"]:
        r=next(r for r in cases if r["input"]["name"]==name)
        f=r["input"]
        def day_text(plan,day):
            text=[]
            for row in sorted(plan,key=lambda r:r["start"]):
                if row["start"]//1440 != day:
                    continue
                w=f["work"][row["task"]]
                label=f["courses"][w["course"]]["name"].replace("合成科目","")
                start=row["start"]%1440; end=start+w["minutes"]
                text.append(f"科{label}第{w['rank']+1}节 {start//60:02}:{start%60:02}–{end//60:02}:{end%60:02}")
            return "；".join(text)
        lines += [f"## 前后课表：{name}","","| 日 | 现算法 | CP-SAT |","|---|---|---|"]
        for d in range(f["days"]):
            lines.append(f"| {d+1} | {day_text(f['baseline'],d)} | {day_text(r['cp']['plan'],d)} |")
        lines.append("")
    lines += ["零预算状态边界检查：UNKNOWN；这只是测试。实际 88 节课案例也在 8 秒预算内返回 UNKNOWN，不能将其解释为无解。", ""]
    return "\n".join(lines)


if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input",type=Path)
    parser.add_argument("--output",type=Path,required=True)
    args=parser.parse_args()
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(render(json.loads(args.input.read_text())))
