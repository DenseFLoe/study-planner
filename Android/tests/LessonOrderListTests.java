package local.studyplanner;

import java.util.*;

public final class LessonOrderListTests {
    static int checks;
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
    public static void main(String[] args) {
        Map<String, String> names = new LinkedHashMap<>(); List<String> order = new ArrayList<>();
        for (int i = 1; i <= 123; i++) { String id = "lesson-" + i; order.add(id); names.put(id, "TEST " + i + (i % 2 == 0 ? " 重点复习" : " 普通")); }
        List<String> before = new ArrayList<>(order); LessonOrderList list = new LessonOrderList(names);
        LessonOrderList.Page first = list.find(order, "", 0), second = list.find(order, "", 1), last = list.find(order, "", 2);
        check(first.count == 123 && first.pageCount == 3, "Lesson list truncated");
        check(first.rows.size() == 50 && second.rows.size() == 50 && last.rows.size() == 23, "Wrong page bounds");
        Set<String> ids = new HashSet<>(); for (LessonOrderList.Page page : Arrays.asList(first, second, last)) for (LessonOrderList.Row row : page.rows) ids.add(row.id);
        check(ids.equals(new HashSet<>(order)), "Paging loses or duplicates lessons");
        check(second.rows.get(0).position == 51 && last.rows.get(22).position == 123, "Display positions are relative to a page");
        LessonOrderList.Page filtered = list.find(order, "ＴＥＳＴ　重点", 1);
        check(filtered.count == 61 && filtered.rows.size() == 11, "Normalized combined search failed");
        check(filtered.rows.get(0).position == 102 && filtered.rows.get(0).id.equals("lesson-102"), "Filtered positions do not refer to full order");
        check(list.find(order, "　", 0).count == 123, "Blank full-width search did not restore lessons");
        check(list.find(order, "", -10).index == 0 && list.find(order, "", Integer.MAX_VALUE).index == 2, "Page not clamped");
        check(order.equals(before), "Search mutated the editable order");
        try { filtered.rows.clear(); throw new AssertionError("Page rows mutable"); } catch (UnsupportedOperationException expected) { checks++; }
        names.put("lesson-1", "External mutation");
        check(list.find(order, "普通", 0).rows.get(0).name.equals("TEST 1 普通"), "Name index retained mutable caller map");
        Collections.reverse(order);
        check(list.find(order, "", 0).rows.get(0).id.equals("lesson-123"), "Reordered draft used stale position");
        check(list.find(order, "test 123", 0).rows.get(0).position == 1, "Search did not update absolute position after move");
        order.subList(45, order.size()).clear();
        check(list.find(order, "", 2).index == 0 && list.find(order, "", 2).rows.size() == 45, "Deletion left an inaccessible page");
        check(first.rows.get(0).id.equals("lesson-1") && first.rows.get(0).position == 1, "Returned page changed after draft edit");
        LessonOrderList.Page empty = list.find(order, "unmatched", 10);
        check(empty.rows.isEmpty() && empty.pageCount == 0 && empty.index == 0, "Empty result has phantom page");
        check(list.find(Collections.emptyList(), "", 0).count == 0, "Empty order contains removed lessons");
        check(list.find(Collections.singletonList("unknown"), "UNKNOWN", 0).rows.get(0).name.equals("unknown"), "Missing label has no stable fallback");
        order.clear(); names.clear(); for (int i = 0; i < 10000; i++) { order.add("scale-" + i); names.put("scale-" + i, "规模课节 " + i); }
        LessonOrderList.Page scale = new LessonOrderList(names).find(order, "规模课节", 199);
        check(scale.count == 10000 && scale.rows.size() == 50 && scale.rows.get(49).position == 10000, "Large draft truncated or exceeded page limit");
        System.out.println("Lesson order list: " + checks + " checks passed");
    }
}
