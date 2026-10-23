"""Independent small exhaustive oracle and hard-constraint boundary checks."""
import itertools
import unittest

from compare import solve, score, validate


def problem(lengths, windows, floating=()):
    days = max(b for a,b in windows)//1440+1
    return {"name":"unit-synthetic", "days":days, "floor":0,
            "work":[{"course":c,"rank":i,"minutes":v,"lesson":str(i)} for c,row in enumerate(lengths) for i,v in enumerate(row)],
            "courses":[{"start":0,"end":days*1440,"weight":1,"priority":2} for _ in lengths],
            "rules":["diversity","dailyWeight","coursePriority","balancedLoad"],"defaultOrder":True,
            "windows":windows,"eventWindows":[[0,days*1440]],"floating":list(floating),
            "scoreWindows":[[[a,b] for a,b in windows if a//1440==d] for d in range(days)]}


def exhaustive(f):
    # Enumerate every chronological permutation and every window assignment.
    # First-fit in a chosen window is sufficient: only the last score uses time,
    # and delaying a study cannot improve any preceding component.
    best, count = None, 0
    for order in itertools.permutations(range(len(f["work"]))):
        for windows in itertools.combinations_with_replacement(range(len(f["windows"])),len(order)):
            plan, cursor = [], -10000
            for t,k in zip(order,windows):
                a,b=f["windows"][k]
                start=max(a,cursor)
                if start+f["work"][t]["minutes"]>b:
                    break
                plan.append({"task":t,"start":start})
                cursor=start+f["work"][t]["minutes"]+15
            else:
                if not validate(f,plan):
                    count+=1
                    values=score(f,plan)
                    if best is None or values<best:
                        best=values
    return best,count


class ModelTests(unittest.TestCase):
    def test_all_levels_match_independent_exhaustion(self):
        f=problem([[30,45],[45],[30]],[[480,615],[1920,2055]])
        expected,count=exhaustive(f)
        self.assertGreater(count,0)
        result=solve(f,5)
        self.assertTrue(result["allLevelsOptimal"])
        self.assertEqual(score(f,result["plan"]),expected)

    def test_no_tail_rest_inside_window(self):
        f=problem([[60]],[[480,540]])
        self.assertEqual(solve(f,2)["status"],"OPTIMAL")

    def test_rest_crosses_windows(self):
        f=problem([[60],[60]],[[480,540],[550,610]])
        self.assertEqual(solve(f,2)["status"],"INFEASIBLE")

    def test_rest_crosses_midnight(self):
        f=problem([[30],[30]],[[1410,1440],[1445,1475]])
        self.assertEqual(solve(f,2)["status"],"INFEASIBLE")

    def test_fixed_event_is_not_a_study_needing_rest(self):
        f=problem([[60]],[[540,600]])
        # Window begins exactly at the end of an exact appointment.
        self.assertEqual(solve(f,2)["plan"][0]["start"],540)

    def test_floating_event_may_be_outside_study(self):
        f=problem([[60]],[[600,660]],[{"start":540,"end":660,"minutes":60}])
        r=solve(f,2)
        self.assertEqual(r["floatingStarts"],[540])
        self.assertFalse(validate(f,r["plan"],r["floatingStarts"]))

    def test_order_blocks_shorter_later_lesson(self):
        f=problem([[90,30]],[[480,510],[600,690]])
        self.assertEqual(solve(f,2)["status"],"INFEASIBLE")

    def test_deadline_and_start_are_hard(self):
        f=problem([[60]],[[480,540],[1920,1980]])
        f["courses"][0].update(start=1440,end=2880)
        self.assertEqual(solve(f,2)["plan"][0]["start"],1920)
        f["courses"][0]["end"]=1440
        self.assertEqual(solve(f,2)["status"],"INFEASIBLE")

    def test_zero_budget_is_unknown(self):
        f=problem([[60]],[[480,540]])
        self.assertEqual(solve(f,0)["status"],"UNKNOWN")

    def test_locked_placement_cannot_be_improved_away(self):
        f=problem([[60],[60]],[[480,720],[1920,2160]])
        f["locked"]={"0":1920}
        r=solve(f,2)
        self.assertIn({"task":0,"start":1920},r["plan"])
        self.assertFalse(validate(f,r["plan"]))


if __name__=="__main__":
    unittest.main()
