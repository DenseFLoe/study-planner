package local.studyplanner;

import java.time.LocalDate;
import java.util.*;

public final class EventConflictReviewTests {
    static int checks;
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
    static void rejected(Runnable action) { try { action.run(); throw new AssertionError("Invalid choice accepted"); } catch (IllegalArgumentException expected) { checks++; } }
    static Planner.EventConflict conflict(LocalDate date, String reason) {
        return new Planner.EventConflict("synthetic", "核对事项", date, 480, 540, 500, 560, null, reason);
    }
    public static void main(String[] args) {
        LocalDate first = LocalDate.of(2026, 11, 4); List<Planner.EventConflict> source = new ArrayList<>();
        for (int i = 60; i >= 0; i--) source.add(conflict(first.plusDays(i), "overlap"));
        source.add(conflict(first.plusDays(42), "active"));
        EventConflictReview review = new EventConflictReview(source); source.clear();
        check(review.dayCount() == 61 && review.conflictCount == 62 && review.pageCount() == 4, "Grouping or source isolation failed");
        check(review.page(0).size() == 20 && review.page(3).size() == 1 && review.page(-1).isEmpty() && review.page(4).isEmpty(), "Page bounds failed");
        check(review.page(0).get(0).date.equals(first), "Dates not sorted");
        check(review.remaining() == 61 && review.firstUnresolvedPage() == 0 && !review.complete(), "Initial progress wrong");
        for (EventConflictReview.Day day : review.page(0)) review.choose(day.date, EventConflictReview.Choice.SKIP_LOCAL);
        check(review.remaining() == 41 && review.firstUnresolvedPage() == 1, "Unresolved page ignored earlier selections");
        review.choose(first.plusDays(60), EventConflictReview.Choice.SKIP_NEW);
        check(review.choice(first) == EventConflictReview.Choice.SKIP_LOCAL && review.choice(first.plusDays(60)) == EventConflictReview.Choice.SKIP_NEW, "Choices lost across pages");
        Set<LocalDate> snapshot = review.skipped(EventConflictReview.Choice.SKIP_NEW);
        review.choose(first.plusDays(60), EventConflictReview.Choice.SKIP_LOCAL);
        check(snapshot.contains(first.plusDays(60)) && review.skipped(EventConflictReview.Choice.SKIP_NEW).isEmpty(), "Submission snapshot aliases choices");
        check(!review.page(2).get(2).canSkipLocal && review.page(2).get(2).conflicts.size() == 2 && !review.canSkipAllLocal(), "Active task not protected across pages");
        rejected(() -> review.choose(first.plusDays(42), EventConflictReview.Choice.SKIP_LOCAL));
        rejected(() -> review.choose(first.minusDays(1), EventConflictReview.Choice.SKIP_NEW));
        rejected(() -> review.chooseAll(EventConflictReview.Choice.SKIP_LOCAL));
        check(review.remaining() == 40 && review.choice(first) == EventConflictReview.Choice.SKIP_LOCAL, "Rejected bulk choice cleared existing choices");
        review.chooseAll(EventConflictReview.Choice.SKIP_NEW);
        check(review.complete() && review.remaining() == 0 && review.firstUnresolvedPage() == -1 && review.skipped(EventConflictReview.Choice.SKIP_NEW).size() == 61, "Bulk save missed other pages");
        review.choose(first.plusDays(42), EventConflictReview.Choice.UNRESOLVED);
        check(!review.complete() && review.firstUnresolvedPage() == 2, "Single cleared choice not found");
        review.chooseAll(EventConflictReview.Choice.UNRESOLVED);
        check(review.remaining() == 61 && review.skipped(EventConflictReview.Choice.SKIP_LOCAL).isEmpty(), "Clear did not cover all pages");
        EventConflictReview empty = new EventConflictReview(Collections.emptyList());
        check(!empty.complete() && !empty.canSkipAllLocal() && empty.pageCount() == 0 && empty.firstUnresolvedPage() == -1, "Empty review was saveable");
        for (int i = 0; i < 5000; i++) source.add(conflict(first.plusDays(i), "overlap"));
        EventConflictReview large = new EventConflictReview(source); large.chooseAll(EventConflictReview.Choice.SKIP_LOCAL);
        check(large.complete() && large.pageCount() == 250 && large.page(249).size() == 20 && large.skipped(EventConflictReview.Choice.SKIP_LOCAL).size() == 5000, "Large review truncated dates");
        System.out.println("EventConflictReviewTests: " + checks + " checks passed");
    }
}
