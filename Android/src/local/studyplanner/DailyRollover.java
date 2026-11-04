package local.studyplanner;

import java.time.LocalDate;

/** UI-thread state: only a successful durable save completes a day transition. */
final class DailyRollover {
    static final long RETRY_DELAY_MILLIS = 5 * 60 * 1000L;
    private LocalDate savedDay, failedDay;
    private long failedAt;

    DailyRollover(LocalDate savedDay) { this.savedDay = savedDay; }

    boolean due(LocalDate today, long elapsedMillis) {
        return !today.equals(savedDay) && (!today.equals(failedDay) || elapsedMillis < failedAt ||
                elapsedMillis - failedAt >= RETRY_DELAY_MILLIS);
    }

    void succeeded(LocalDate day) { savedDay = day; failedDay = null; }

    /** Retry silently after the first failure for this day, avoiding stacked dialogs. */
    boolean failed(LocalDate day, long elapsedMillis) {
        boolean first = !day.equals(failedDay);
        failedDay = day; failedAt = elapsedMillis;
        return first;
    }
}
