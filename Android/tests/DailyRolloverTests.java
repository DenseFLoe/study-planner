package local.studyplanner;

import java.time.LocalDate;

public final class DailyRolloverTests {
    static int checks;
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
    public static void main(String[] args) {
        LocalDate original = LocalDate.of(2026, 11, 4), next = original.plusDays(1);
        DailyRollover gate = new DailyRollover(original);
        long delay = DailyRollover.RETRY_DELAY_MILLIS;
        check(!gate.due(original, 0), "Opening day must not be needlessly replanned");
        check(gate.due(next, 100), "New day was not scheduled");
        check(gate.failed(next, 100), "First failure should be visible");
        check(!gate.due(original, 101), "Failed save changed the last committed day");
        check(!gate.due(next, 100 + delay - 1), "Failure retried before the backoff elapsed");
        check(gate.due(next, 100 + delay), "Failed transition was incorrectly considered saved");
        check(!gate.failed(next, 100 + delay), "Repeated failure would stack another alert");
        check(!gate.due(next, 100 + 2 * delay - 1), "Repeated failure did not restart the retry delay");
        check(gate.due(next, 100 + 2 * delay), "Repeated failure prevented eventual retry");
        gate.succeeded(next);
        check(!gate.due(next, 100 + 3 * delay), "Successful transition kept rescheduling");
        LocalDate later = next.plusDays(1);
        check(gate.due(later, 100 + 3 * delay), "Next day was blocked by an older retry");
        check(gate.failed(later, 100 + 3 * delay), "Success did not clear failure reporting");
        check(gate.due(later.plusDays(1), 101 + 3 * delay), "A changed calendar day inherited another day's backoff");
        check(gate.due(later, 0), "Monotonic-clock reset stalled retry indefinitely");
        check(gate.due(original, 100 + 3 * delay), "Moving the calendar backward should still refresh the plan");
        gate.succeeded(original);
        check(!gate.due(original, 100 + 4 * delay), "Backward-day save was not acknowledged");
        System.out.println("Daily rollover: " + checks + " checks passed");
    }
}
