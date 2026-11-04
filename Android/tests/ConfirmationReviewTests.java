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
    static JSONObject taskByID(JSONObject state,String id)throws Exception {
        for(JSONObject task:Planner.list(state.getJSONArray("tasks")))if(task.getString("id").equals(id))return task;
        throw new AssertionError("Missing fixture task");
    }
    static ConfirmationReview.Row find(ConfirmationReview review,String id) {
        for(int page=0;page<review.pageCount();page++)for(ConfirmationReview.Row row:review.page(page))if(row.id.equals(id))return row;
        return null;
    }
    static void refreshAcrossPages() throws Exception {
        JSONObject state=fixture();ConfirmationReview original=review(state);
        ConfirmationReview.Row first=original.page(0).get(0),last=original.page(2).get(10);
        String oldDate=first.studyDate;first.minutes="12.";last.minutes="40";last.studyDate=DAY.minusDays(3).toString();
        String confirmed=state.getJSONArray("tasks").getJSONObject(1).getString("id"),deleted=state.getJSONArray("tasks").getJSONObject(2).getString("id");
        Planner.confirm(state,confirmed,30,NOW,DAY.minusDays(1));
        JSONArray retained=new JSONArray();for(JSONObject task:Planner.list(state.getJSONArray("tasks")))if(!task.getString("id").equals(deleted))retained.put(task);
        state.put("tasks",retained);JSONObject changed=taskByID(state,last.id);changed.put("durationMinutes",30);
        JSONObject added=Planner.task(changed.getString("courseID"),Planner.at(DAY.minusDays(2),900),60);state.getJSONArray("tasks").put(added);
        String before=SyncLedger.canonical(state);ConfirmationReview.Refresh refresh=original.refresh(state,NOW);ConfirmationReview latest=refresh.review;
        check(refresh.added==1&&refresh.changed==1&&refresh.removed==2,"Refresh did not explain new, changed and removed rows");
        check(latest.count()==50&&latest.pageCount()==3,"Refresh lost pagination after removals");
        check(find(latest,first.id).minutes.equals("12.")&&find(latest,first.id).studyDate.equals(oldDate),"Refresh lost raw input or untouched date");
        check(find(latest,last.id).minutes.equals("40")&&find(latest,last.id).studyDate.equals(DAY.minusDays(3).toString()),"Changed row was clamped or lost its explicit date");
        check(find(latest,last.id).needsReview&&find(latest,last.id).maximum==30,"Changed row inherited previous approval");
        check(find(latest,confirmed)==null&&find(latest,deleted)==null,"Confirmed or deleted task remained eligible");
        check(find(latest,added.getString("id")).minutes.isEmpty(),"New task inherited stale input");
        check(before.equals(SyncLedger.canonical(state)),"Refresh mutated planner state");
        find(latest,first.id).minutes="20";find(latest,last.id).minutes="20";rejects(latest,find(latest,last.id).index);
        find(latest,last.id).minutes="";check(latest.submission(NOW).minutes.size()==1,"Blank changed row blocked an independent confirmation");find(latest,last.id).minutes="20";
        latest=latest.refresh(state,NOW).review;check(find(latest,last.id).needsReview,"Repeated refresh silently accepted changed task");
        find(latest,last.id).needsReview=false;ConfirmationReview.Submission saved=latest.submission(NOW);
        check(saved.minutes.size()==2&&!saved.minutes.containsKey(confirmed)&&!saved.minutes.containsKey(deleted),"Refresh reintroduced removed input into submission");
        JSONObject copy=CourseTools.copy(state);latest.draft.apply(copy,saved.minutes,saved.dates,NOW);
        check(copy.getJSONArray("completions").length()==3&&Planner.completed(copy,copy.getJSONArray("courses").getJSONObject(0))==70,"Fresh draft did not preserve remote confirmation and new values");
        changed.put("start",changed.getDouble("start")+60);String newer=SyncLedger.canonical(state);
        try{latest.draft.apply(state,saved.minutes,saved.dates,NOW);throw new AssertionError("Post-refresh remote change accepted");}
        catch(IllegalArgumentException expected){check(newer.equals(SyncLedger.canonical(state)),"Post-refresh conflict partially saved rows");}
        ConfirmationReview.Refresh again=latest.refresh(state,NOW);check(again.changed==1&&find(again.review,last.id).needsReview,"Second task change retained old approval");
        original.page(0).get(0).minutes="99";check(find(again.review,first.id).minutes.equals("20"),"Refresh retained mutable old row");
        state.put("tasks",new JSONArray());ConfirmationReview.Refresh empty=again.review.refresh(state,NOW);
        check(empty.review.count()==0&&empty.review.pageCount()==0&&empty.removed==again.review.count(),"Empty refresh retained hidden pages");
    }
    public static void main(String[] args) throws Exception {
        pagingAndInputs(); staleBatch(); refreshAcrossPages(); System.out.println("Confirmation review: " + checks + " checks passed");
    }
}
