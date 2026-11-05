package local.studyplanner;

import org.json.JSONObject;
import java.util.*;

/** Freezes UI choices cheaply; lesson validation and netdisk merging run on the worker. */
final class CourseImportRequest {
    private final List<JSONObject> captures;
    private final Set<String> selected;
    private final String mergeName;
    final double deadline;

    // Captured JSON is read-only after publication by CourseImportActivity. Copy only
    // the containers here: serializing every lesson would block the UI before dispatch.
    CourseImportRequest(List<JSONObject> captures, Set<String> selected, String mergeName, double deadline) {
        this.captures = new ArrayList<>(captures);
        this.selected = new HashSet<>(selected);
        this.mergeName = mergeName;
        this.deadline = deadline;
    }

    List<JSONObject> prepare() throws Exception {
        List<JSONObject> data = new ArrayList<>();
        Set<String> found = new HashSet<>();
        for (JSONObject capture : captures) {
            String id = WebCourseImport.identity(capture);
            if (!selected.contains(id)) continue;
            if (!CourseImportCatalog.importable(capture)) throw new IllegalArgumentException("请选择完整课程。");
            if (!found.add(id)) throw new IllegalArgumentException("所选课程标识重复，请重新读取后核对。");
            data.add(capture);
        }
        if (!found.equals(selected)) throw new IllegalArgumentException("部分所选课程已不存在，请重新核对选择。");
        if (data.isEmpty()) throw new IllegalArgumentException("请先选择课程。");
        return mergeName == null ? Collections.unmodifiableList(data)
            : Collections.singletonList(NetdiskImport.merge(data, mergeName));
    }
}
