package local.studyplanner;

/** Reserves an entire sync or configuration save, including asynchronous I/O. */
final class CloudOperationGate {
    enum Operation { SYNC, CONFIGURATION }
    private Operation active;
    synchronized boolean begin(Operation operation) {
        if (active != null) return false;
        active = operation; return true;
    }
    synchronized boolean isActive(Operation operation) { return active == operation; }
    synchronized void finish(Operation operation) {
        if (active != operation) throw new IllegalStateException("Cloud operation ownership changed");
        active = null;
    }
}
