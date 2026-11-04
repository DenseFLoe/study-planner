package local.studyplanner;

/** A read-modify-save operation shares the same monitor as cloud commits. */
public final class StateMutation {
    private StateMutation() {}
    public interface Store<T> {
        T load() throws Exception;
        void save(T value) throws Exception;
    }
    public interface Change<T> { void apply(T value) throws Exception; }

    public static <T> T apply(Store<T> store, Change<T> change) throws Exception {
        synchronized (store) {
            T latest = store.load();
            change.apply(latest);
            store.save(latest);
            return latest;
        }
    }
}
