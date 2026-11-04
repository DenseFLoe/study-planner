package local.studyplanner;

import java.time.LocalDate;
import java.util.*;

/** Choices belong to reviewed dates, not the currently displayed page. */
final class EventConflictReview {
    static final int PAGE_SIZE = 20;
    enum Choice { UNRESOLVED, SKIP_NEW, SKIP_LOCAL }
    static final class Day {
        final LocalDate date;
        final List<Planner.EventConflict> conflicts;
        final boolean canSkipLocal;
        Day(LocalDate date, List<Planner.EventConflict> conflicts) {
            this.date = date; this.conflicts = Collections.unmodifiableList(new ArrayList<>(conflicts));
            canSkipLocal = conflicts.stream().noneMatch(item -> "active".equals(item.reason));
        }
    }
    private final List<Day> days;
    private final Map<LocalDate, Day> byDate = new HashMap<>();
    private final Map<LocalDate, Choice> choices = new HashMap<>();
    final int conflictCount;
    EventConflictReview(List<Planner.EventConflict> conflicts) {
        conflictCount = conflicts.size(); Map<LocalDate, List<Planner.EventConflict>> grouped = new TreeMap<>();
        for (Planner.EventConflict conflict : conflicts) grouped.computeIfAbsent(conflict.date, key -> new ArrayList<>()).add(conflict);
        List<Day> rows = new ArrayList<>();
        for (Map.Entry<LocalDate, List<Planner.EventConflict>> entry : grouped.entrySet()) {
            Day day = new Day(entry.getKey(), entry.getValue()); rows.add(day); byDate.put(day.date, day);
        }
        days = Collections.unmodifiableList(rows);
    }
    int dayCount() { return days.size(); }
    int pageCount() { return days.isEmpty() ? 0 : (days.size() - 1) / PAGE_SIZE + 1; }
    List<Day> page(int index) {
        if (index < 0 || index >= pageCount()) return Collections.emptyList();
        int first = index * PAGE_SIZE; return days.subList(first, Math.min(days.size(), first + PAGE_SIZE));
    }
    Choice choice(LocalDate date) { return choices.getOrDefault(date, Choice.UNRESOLVED); }
    void choose(LocalDate date, Choice choice) {
        Day day = byDate.get(date);
        if (day == null || choice == null) throw new IllegalArgumentException("请选择列表内的冲突日期");
        if (choice == Choice.SKIP_LOCAL && !day.canSkipLocal) throw new IllegalArgumentException("正在进行的学习任务不能跳过");
        if (choice == Choice.UNRESOLVED) choices.remove(date); else choices.put(date, choice);
    }
    boolean canSkipAllLocal() { return !days.isEmpty() && days.stream().allMatch(day -> day.canSkipLocal); }
    void chooseAll(Choice choice) {
        if (choice == null || choice == Choice.SKIP_LOCAL && !canSkipAllLocal()) throw new IllegalArgumentException("不能跳过全部本地安排");
        choices.clear();
        if (choice != Choice.UNRESOLVED) for (Day day : days) choices.put(day.date, choice);
    }
    int remaining() { return days.size() - choices.size(); }
    boolean complete() { return !days.isEmpty() && remaining() == 0; }
    int firstUnresolvedPage() {
        for (int i = 0; i < days.size(); i++) if (!choices.containsKey(days.get(i).date)) return i / PAGE_SIZE;
        return -1;
    }
    Set<LocalDate> skipped(Choice choice) {
        Set<LocalDate> selected = new HashSet<>();
        for (Map.Entry<LocalDate, Choice> entry : choices.entrySet()) if (entry.getValue() == choice) selected.add(entry.getKey());
        return Collections.unmodifiableSet(selected);
    }
}
