package local.studyplanner;

import org.json.*;
import java.time.LocalDate;
import java.util.*;

public final class ConfirmationReviewTests {
    static int checks;
    static final LocalDate DAY = LocalDate.of(2026, 11, 4);
    static final double NOW = Planner.at(DAY, 720);
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
    static JSONObject fixture() throws Exception {
        JSONObject state = PlannerTests.empty(), course = PlannerTests.course("高数", 3060, DAY.minusDays(60), DAY.plusDays(1), 60);
        state.getJSONArray("courses").put(course);
        for (int i = 0; i < 51; i++) state.getJSONArray("tasks").put(Planner.task(course.getString("id"), Planner.at(DAY.minusDays(51 - i), 480), 60).put("lessonName", "第 " + i + " 节"));
        return state;
    }
    static ConfirmationReview review(JSONObject state) throws Exception { return new ConfirmationReview(state, Planner.review(state, NOW), NOW); }
    static void rejects(ConfirmationReview review, int index) {
        try { review.submission(NOW); throw new AssertionError("Invalid input accepted"); }
        catch (ConfirmationReview.InputError error) { check(error.index == index && error.getMessage().contains("第 " + (index + 1) + " 项"), "Error did not locate the original row/page"); }
    }
    static void pagingAndInputs() throws Exception {
        JSONObject state = fixture(); String before = SyncLedger.canonical(state); ConfirmationReview review = review(state);
        check(review.count() == 51 && review.pageCount() == 3, "Incorrect review count");
        check(review.page(0).size() == 20 && review.page(1).size() == 20 && review.page(2).size() == 11, "Review truncated or exceeded page size");
        check(review.page(-1).isEmpty() && review.page(3).isEmpty(), "Invalid pages accepted");
        ConfirmationReview.Row first = review.page(0).get(0), middle = review.page(1).get(0), last = review.page(2).get(10);
        first.minutes = "12."; last.minutes = "0"; last.studyDate = DAY.minusDays(1).toString();
        check(review.page(0).get(0).minutes.equals("12.") && review.page(2).get(10).studyDate.equals(DAY.minusDays(1).toString()), "Paging lost raw input or study date");
        rejects(review, 0); first.minutes = "20"; middle.minutes = "61"; rejects(review, 20);
        middle.minutes = "10"; middle.studyDate = "not a date"; rejects(review, 20);
        middle.studyDate = DAY.plusDays(1).toString(); rejects(review, 20); middle.studyDate = DAY.toString();
        review.page(0).get(1).studyDate = "invalid but unfilled";
        ConfirmationReview.Submission saved = review.submission(NOW);
        check(saved.minutes.size() == 3 && saved.minutes.get(first.id) == 20 && saved.minutes.get(last.id) == 0, "Save omitted other pages, treated blanks as zero, or lost explicit zero");
        check(saved.dates.get(last.id).equals(DAY.minusDays(1)), "Save lost actual learning date");
        first.minutes = "30"; check(saved.minutes.get(first.id) == 20, "Submitted values changed after further edits");
        try { saved.minutes.clear(); throw new AssertionError("Submission is mutable"); } catch (UnsupportedOperationException expected) { checks++; }
        check(SyncLedger.canonical(state).equals(before), "Review or validation mutated planner");
        review.draft.apply(state, saved.minutes, saved.dates, NOW);
        check(state.getJSONArray("completions").length() == 3 && Planner.completed(state, state.getJSONArray("courses").getJSONObject(0)) == 30, "Cross-page batch did not save exactly the filled rows");
        check(Planner.review(state, NOW).size() == 48, "Unfilled review rows were consumed");
    }
    static void staleBatch() throws Exception {
        JSONObject state = fixture(); ConfirmationReview review = review(state);
        review.page(0).get(0).minutes = "20"; review.page(2).get(10).minutes = "10";
        ConfirmationReview.Submission input = review.submission(NOW);
        state.getJSONArray("tasks").getJSONObject(50).put("durationMinutes", 30); String changed = SyncLedger.canonical(state);
        check(review.page(2).get(10).maximum == 60, "Review retained mutable task fields");
        try { review.draft.apply(state, input.minutes, input.dates, NOW); throw new AssertionError("Stale hidden-page row accepted"); }
        catch (IllegalArgumentException expected) { check(SyncLedger.canonical(state).equals(changed), "Stale batch partly confirmed other pages"); }
        ConfirmationReview empty = new ConfirmationReview(state, Collections.emptyList(), NOW);
        check(empty.pageCount() == 0 && empty.page(0).isEmpty(), "Empty review has phantom page");
        try { empty.submission(NOW); throw new AssertionError("Empty submission accepted"); }
        catch (IllegalArgumentException expected) { checks++; }
    }
    public static void main(String[] args) throws Exception {
        pagingAndInputs(); staleBatch(); System.out.println("Confirmation review: " + checks + " checks passed");
    }
}
