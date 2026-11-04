package local.studyplanner;

import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import static local.studyplanner.CloudOperationGate.Operation.*;

public final class CloudOperationGateTests {
    static int checks;
    static void check(boolean value, String message) { checks++; if (!value) throw new AssertionError(message); }
    public static void main(String[] args) throws Exception {
        CloudOperationGate gate = new CloudOperationGate();
        check(gate.begin(CONFIGURATION), "Could not reserve configuration save");
        check(!gate.begin(SYNC) && !gate.begin(CONFIGURATION), "Network request or second save interrupted reserved configuration");
        try { gate.finish(SYNC); throw new AssertionError("Wrong operation released reservation"); }
        catch (IllegalStateException expected) { check(gate.isActive(CONFIGURATION), "Invalid completion unlocked an active configuration save"); }
        gate.finish(CONFIGURATION);
        check(gate.begin(SYNC) && !gate.begin(CONFIGURATION), "Active network sync allowed a configuration replacement");
        gate.finish(SYNC);
        check(gate.begin(CONFIGURATION), "Finished sync blocked subsequent configuration"); gate.finish(CONFIGURATION);
        ExecutorService threads = Executors.newFixedThreadPool(2);
        try {
            for (int i = 0; i < 200; i++) {
                CloudOperationGate race = new CloudOperationGate(); CountDownLatch start = new CountDownLatch(1), attempted = new CountDownLatch(2);
                AtomicInteger winners = new AtomicInteger();
                Future<?> sync = threads.submit(() -> compete(race, SYNC, start, attempted, winners));
                Future<?> config = threads.submit(() -> compete(race, CONFIGURATION, start, attempted, winners));
                start.countDown(); sync.get(5, TimeUnit.SECONDS); config.get(5, TimeUnit.SECONDS);
                check(winners.get() == 1, "Simultaneous sync and config both started or both failed");
                check(race.begin(SYNC), "Completion leaked its reservation"); race.finish(SYNC);
            }
        } finally { threads.shutdownNow(); }
        System.out.println("Cloud operation gate: " + checks + " checks passed");
    }
    static void compete(CloudOperationGate gate, CloudOperationGate.Operation operation, CountDownLatch start,
                        CountDownLatch attempted, AtomicInteger winners) {
        try {
            start.await(); boolean acquired = gate.begin(operation);
            if (acquired) winners.incrementAndGet(); attempted.countDown();
            if (!attempted.await(5, TimeUnit.SECONDS)) throw new AssertionError("Competing request did not finish");
            if (acquired) gate.finish(operation);
        } catch (InterruptedException error) { Thread.currentThread().interrupt(); throw new AssertionError(error); }
    }
}
