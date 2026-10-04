import XCTest
import WebKit
@testable import StudyPlanner
import StudyCore

private final class ReplayProbe: NSObject, WKScriptMessageHandler {
    let expectation: XCTestExpectation
    var metadata: [String: Any]?
    init(_ expectation: XCTestExpectation) { self.expectation = expectation }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard metadata == nil, let body = message.body as? [String: Any] else { return }
        metadata = body
        expectation.fulfill()
    }
}

final class WebLessonReaderTests: XCTestCase {
    @MainActor
    func ready(_ reader: WebLessonReader) async throws {
        reader.webView.loadHTMLString("<html><body>抓取器测试</body></html>", baseURL: URL(string: "https://www.kaoyanvip.cn/"))
        for _ in 0..<60 {
            if (try? await reader.webView.evaluateJavaScript("typeof window.studyCourseCrawler")) as? String == "object" { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Crawler resource did not load")
    }
    @MainActor
    func testAllPagesSubjectsStagesAndProgress() async throws {
        let reader = WebLessonReader(); defer { reader.stop() }
        try await ready(reader)
        let script = #"""
        const request = async (path, params) => {
          if (path.includes('/course/mycourse')) {
            if (path.endsWith('/invalid') || params.p_type === 2 || params.is_display === 0) return {results:[], current_page:1, total_page:0, count:0};
            return {results:[{my_delivery_id:params.page, name:'课程'+params.page}], current_page:params.page, total_page:2, count:2};
          }
          if (path.includes('/my_delivery/info')) return {name:'测试课程', outlines:[{delivery_outline_id:1,name:'数学'},{delivery_outline_id:2,name:'英语'}],oto:[]};
          return {outline:[{stage_name:'基础',children:[{name:'隐藏章节',course_sections:[{course_section_id:params.delivery_outline_id,name:'课节',mold:'video',publish_status:'published',video:{duration:120000},percent:50,is_mark_finished:true}]}]},
            {stage_name:'强化',children:[{name:'未展开',course_sections:[{course_section_id:params.delivery_outline_id+10,name:'未发布',mold:'video',publish_status:'unpublished',percent:0}]}]}]};
        };
        return JSON.stringify(await window.studyCourseCrawler.account(request));
        """#
        let result = try await reader.webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        let account = try decoder.decode(WebCourseAccount.self, from: Data(try XCTUnwrap(result as? String).utf8))
        XCTAssertEqual(account.snapshots.count, 2)
        XCTAssertTrue(account.issues.isEmpty)
        let snapshot = try XCTUnwrap(account.snapshots.first)
        XCTAssertEqual(snapshot.lessons.count, 4)
        XCTAssertEqual(snapshot.lessons.map(\.id), ["1:1", "1:11", "1:2", "1:12"],
                       "Keep the site's subject and outline traversal order")
        XCTAssertEqual(snapshot.fetchedOutlines, 2)
        XCTAssertEqual(snapshot.totalSeconds, 240)
        XCTAssertEqual(snapshot.watchedSeconds, 120, "Manual finish must not overwrite actual watch percentage")
        XCTAssertEqual(snapshot.remainingMinutes, 2)
        XCTAssertNil(snapshot.importProblem)
    }
    @MainActor
    func testAddressBarKeepsTheTargetWhenTheAddressIsNotHTTPS() {
        let reader = WebLessonReader(); defer { reader.stop() }
        XCTAssertEqual(reader.address, WebLessonReader.defaultAddress)
        XCTAssertEqual(reader.targetURL, WebLessonReader.defaultURL)
        reader.address = "http://example.com/appmanage/my/mycourse"
        reader.loadAddress()
        XCTAssertEqual(reader.targetURL, WebLessonReader.defaultURL, "A rejected address must not move the reader")
        XCTAssertTrue(reader.status.contains("HTTPS"))
    }
    @MainActor
    func testFailedSubjectIsNotComplete() async throws {
        let reader = WebLessonReader(); defer { reader.stop() }
        try await ready(reader)
        let result = try await reader.webView.callAsyncJavaScript(#"""
        const request = async (path, params) => {
          if (path.includes('/my_delivery/info')) return {name:'课程',outlines:[{delivery_outline_id:1,name:'数学'}]};
          throw Error('登录失效');
        };
        return JSON.stringify(await window.studyCourseCrawler.collect('1',request));
        """#, arguments: [:], in: nil, contentWorld: .page)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        let snapshot = try decoder.decode(WebCourseSnapshot.self, from: Data(try XCTUnwrap(result as? String).utf8))
        XCTAssertEqual(snapshot.fetchedOutlines, 0)
        XCTAssertNotNil(snapshot.importProblem)
        XCTAssertEqual(snapshot.issues.count, 1)
    }

    @MainActor
    func testXuechengCatalogExpandsGroupsAndKeepsReplayRows() async throws {
        let reader = WebLessonReader(); defer { reader.stop() }
        reader.webView.loadHTMLString(#"""
        <html><body>
          <div>2027学丞考研英语</div><div>课程有效期：2026-12-31</div>
          <button onclick="document.getElementById('hidden').style.display='block'; this.textContent='收起'">展开</button>
          <div class="cursor-pointer" onclick="window.clickedReplay=true">
            <img src="/assets/ic_course_live-test.png"><div><span>阅读 T1+T2</span><span>直播回放</span></div>
          </div>
          <div id="hidden" style="display:none"><div class="cursor-pointer">
            <img src="/assets/ic_course_live-test.png"><div><span>下周直播</span><span>直播时间：2026-10-01 19:00</span></div>
          </div></div>
        </body></html>
        """#, baseURL: URL(string: "https://www.ixuecheng.cn/detail?id=88&type=1"))
        for _ in 0..<60 {
            if (try? await reader.webView.evaluateJavaScript("typeof window.studyXuechengCrawler")) as? String == "object" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let value = try await reader.webView.callAsyncJavaScript("return JSON.stringify(await window.studyXuechengCrawler.catalog());", arguments: [:], in: nil, contentWorld: .page)
        let catalog = try XCTUnwrap(value as? String)
        XCTAssertTrue(catalog.contains("阅读 T1+T2"))
        XCTAssertTrue(catalog.contains("下周直播"))
        XCTAssertTrue(catalog.contains("2027学丞考研英语"))
        let opened = try await reader.webView.callAsyncJavaScript("return (await window.studyXuechengCrawler.open(0)) && window.clickedReplay === true;", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(opened as? Bool, true)
    }

    @MainActor
    func testXuechengExpansionIgnoresHiddenLabelsAndDoesNotToggleOpenGroups() async throws {
        let reader = WebLessonReader(); defer { reader.stop() }
        reader.webView.loadHTMLString(#"""
        <html><body>
          <div>测试课程</div><div>课程有效期：2026-12-31</div>
          <div role="tab" id="group" aria-expanded="false" onclick="
            window.groupClicks=(window.groupClicks||0)+1;
            const opened=this.getAttribute('aria-expanded')==='true';
            this.setAttribute('aria-expanded', String(!opened));
            this.querySelector('.expand').style.display=opened?'inline':'none';
            this.querySelector('.collapse').style.display=opened?'none':'inline';
            if (!opened) setTimeout(() => document.getElementById('lessons').innerHTML=
              '<div class=cursor-pointer><img src=/ic_course_live-test.png><span>延迟加载的课节</span><span>直播回放</span></div>', 700);
          ">
            <span>第一章</span><span class="expand">展开</span><span class="collapse" style="display:none">收起</span>
          </div>
          <div id="lessons"></div>
        </body></html>
        """#, baseURL: URL(string: "https://www.ixuecheng.cn/detail?id=89&type=1"))
        for _ in 0..<60 {
            if (try? await reader.webView.evaluateJavaScript("typeof window.studyXuechengCrawler")) as? String == "object" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let value = try await reader.webView.callAsyncJavaScript(#"""
        const first = await window.studyXuechengCrawler.catalog();
        const second = await window.studyXuechengCrawler.catalog();
        return JSON.stringify({count: window.groupClicks, expanded: document.getElementById('group').getAttribute('aria-expanded'), first, second});
        """#, arguments: [:], in: nil, contentWorld: .page)
        let data = Data(try XCTUnwrap(value as? String).utf8)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(result["count"] as? Int, 1)
        XCTAssertEqual(result["expanded"] as? String, "true")
        let first = try XCTUnwrap(result["first"] as? [String: Any])
        XCTAssertEqual((first["rows"] as? [[String: Any]])?.count, 1, "Wait for asynchronously rendered lessons")
    }

    @MainActor
    func testXuechengTraversesNestedExclusiveAccordionOnceAndReopensCorrectReplay() async throws {
        let reader = WebLessonReader(); defer { reader.stop() }
        reader.webView.loadHTMLString(#"""
        <html><body><div>互斥目录测试</div><div>课程有效期：2026-12-31</div>
        <div id="catalog" class="ant-collapse" role="tablist"></div>
        <script>
          window.clicks = {};
          function addGroup(list, id, nested) {
            const item = document.createElement('div'); item.className = 'ant-collapse-item';
            const head = document.createElement('div'); head.className = 'ant-collapse-header';
            head.setAttribute('role', 'tab'); head.setAttribute('aria-expanded', 'false');
            head.textContent = id; // Second-level controls have no “展开” label.
            head.onclick = () => {
              clicks[id] = (clicks[id] || 0) + 1;
              const wasOpen = head.getAttribute('aria-expanded') === 'true';
              for (const sibling of list.children) {
                sibling.firstElementChild.setAttribute('aria-expanded', 'false');
                sibling.querySelector('.ant-collapse-content')?.remove();
              }
              if (wasOpen) return;
              head.setAttribute('aria-expanded', 'true');
              const panel = document.createElement('div'); panel.className = 'ant-collapse-content';
              panel.setAttribute('role', 'tabpanel'); item.appendChild(panel);
              setTimeout(() => {
                if (nested) {
                  const children = document.createElement('div'); children.className = 'ant-collapse';
                  children.setAttribute('role', 'tablist'); panel.appendChild(children);
                  addGroup(children, id + '1', false); addGroup(children, id + '2', false);
                } else {
                  // An unnamed row must not shift the saved replay index.
                  panel.innerHTML = '<div class="cursor-pointer"><img src="/ic_course_live.png"><span>直播回放</span></div>';
                  const row = document.createElement('div'); row.className = 'cursor-pointer';
                  row.innerHTML = '<img src="/ic_course_live.png"><span>同名回放</span><span>直播回放</span>';
                  row.onclick = () => window.openedLesson = id; panel.appendChild(row);
                }
              }, 650);
            };
            item.appendChild(head); list.appendChild(item);
          }
          addGroup(document.getElementById('catalog'), 'A', true);
          addGroup(document.getElementById('catalog'), 'B', true);
        </script></body></html>
        """#, baseURL: URL(string: "https://www.ixuecheng.cn/detail?id=90&type=1"))
        for _ in 0..<60 {
            if (try? await reader.webView.evaluateJavaScript("typeof window.studyXuechengCrawler")) as? String == "object" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let value = try await reader.webView.callAsyncJavaScript(#"""
        const [first, concurrent] = await Promise.all([window.studyXuechengCrawler.catalog(), window.studyXuechengCrawler.catalog()]);
        const again = await window.studyXuechengCrawler.catalog();
        const clicksBeforeReplay = {...window.clicks};
        const opened = await window.studyXuechengCrawler.open(0);
        return JSON.stringify({first, concurrent, again, clicksBeforeReplay, opened, lesson: window.openedLesson});
        """#, arguments: [:], in: nil, contentWorld: .page)
        let data = Data(try XCTUnwrap(value as? String).utf8)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["first", "concurrent", "again"] {
            let catalog = try XCTUnwrap(result[key] as? [String: Any])
            let rows = try XCTUnwrap(catalog["rows"] as? [[String: Any]])
            XCTAssertEqual(rows.count, 4, key)
            XCTAssertEqual(Set(rows.compactMap { $0["key"] as? String }).count, 4)
        }
        XCTAssertEqual(result["clicksBeforeReplay"] as? [String: Int], ["A": 1, "A1": 1, "A2": 1, "B": 1, "B1": 1, "B2": 1])
        XCTAssertEqual(result["opened"] as? Bool, true)
        XCTAssertEqual(result["lesson"] as? String, "A1", "Reopen the saved branch, not the currently visible row")
    }

    @MainActor
    func testXuechengEmptyBranchContinuesAndWaitsForPendingLessons() async throws {
        let reader = WebLessonReader(); defer { reader.stop() }
        reader.webView.loadHTMLString(#"""
        <html><body><div>空目录测试</div><div>课程有效期：2026-12-31</div>
        <div id="catalog" class="ant-collapse" role="tablist"></div>
        <script>
        let pending = 0, completed = 0;
        window.allEmpty = false;
        window.studyGenericCrawler.activity = () => ({pending, completed, failed: 0});
        for (const name of ['前面的课', '空章节', '后面的课']) {
          const item = document.createElement('div'); item.className = 'ant-collapse-item';
          const head = document.createElement('div'); head.className = 'ant-collapse-header';
          head.setAttribute('role', 'tab'); head.setAttribute('aria-expanded', 'false'); head.textContent = name;
          head.onclick = () => {
            for (const sibling of document.getElementById('catalog').children) {
              sibling.firstElementChild.setAttribute('aria-expanded', 'false');
              sibling.querySelector('.ant-collapse-content')?.remove();
            }
            head.setAttribute('aria-expanded', 'true');
            const panel = document.createElement('div'); panel.className = 'ant-collapse-content'; item.append(panel);
            // The real site's empty response leaves an empty nested tablist, with no empty-state text.
            panel.innerHTML = '<div class="ant-collapse" role="tablist"></div>';
            pending++;
            setTimeout(() => {
              if (!window.allEmpty && name !== '空章节') panel.innerHTML =
                '<div class="cursor-pointer"><img src="/ic_course_live.png"><span>' + name + '</span><span>直播回放</span></div>';
              pending--; completed++;
            }, name === '空章节' ? 200 : 1800);
          };
          item.append(head); document.getElementById('catalog').append(item);
        }
        </script></body></html>
        """#, baseURL: URL(string: "https://www.ixuecheng.cn/detail?id=91&type=1"))
        for _ in 0..<60 {
            if (try? await reader.webView.evaluateJavaScript("typeof window.studyXuechengCrawler")) as? String == "object" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let value = try await reader.webView.callAsyncJavaScript(#"""
        const mixed = await window.studyXuechengCrawler.catalog();
        window.allEmpty = true;
        // Force refresh must wait for new responses and discard the previous catalog entries.
        document.querySelectorAll('.ant-collapse-header').forEach(e => e.setAttribute('aria-expanded', 'false'));
        const empty = await window.studyXuechengCrawler.catalog(true);
        return JSON.stringify({mixed, empty});
        """#, arguments: [:], in: nil, contentWorld: .page)
        let data = Data(try XCTUnwrap(value as? String).utf8)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let mixed = try XCTUnwrap(result["mixed"] as? [String: Any])
        XCTAssertEqual((mixed["rows"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["前面的课", "后面的课"])
        let empty = try XCTUnwrap(result["empty"] as? [String: Any])
        XCTAssertEqual((empty["rows"] as? [[String: Any]])?.count, 0)
    }

    @MainActor
    func testGenericActivityTracksEmptyResponsesAndFailures() async throws {
        let reader = WebLessonReader(); defer { reader.stop() }
        try await ready(reader)
        _ = try await reader.webView.evaluateJavaScript(#"""
        delete window.studyGenericCrawler;
        window.fetch = () => new Promise(resolve => { window.finishFetch = resolve; });
        window.XMLHttpRequest = class extends EventTarget {
          open(method, url) { this.responseURL = new URL(url, location.href).href; }
          send() {}
          finish(status) {
            this.status = status; this.responseText = '[]'; this.responseType = 'text';
            this.dispatchEvent(new Event('load')); this.dispatchEvent(new Event('loadend'));
          }
        };
        true;
        """#)
        _ = try await reader.webView.evaluateJavaScript(WebLessonReader.genericScript)
        let value = try await reader.webView.callAsyncJavaScript(#"""
        const request = fetch('/empty');
        const xhr = new XMLHttpRequest(); xhr.open('GET', '/chapters'); xhr.send();
        const started = window.studyGenericCrawler.activity();
        window.finishFetch(new Response('[]', {status: 200, headers: {'content-type':'application/json'}}));
        await request;
        for (let n = 0; n < 30 && window.studyGenericCrawler.activity().pending !== 1; n++)
          await new Promise(resolve => setTimeout(resolve, 10));
        const fetched = window.studyGenericCrawler.activity();
        xhr.finish(200);
        const completed = window.studyGenericCrawler.activity();
        const failed = new XMLHttpRequest(); failed.open('GET', '/failed'); failed.send(); failed.finish(503);
        const remote = new XMLHttpRequest(); remote.open('GET', 'https://example.com/unrelated'); remote.send(); remote.finish(503);
        return JSON.stringify({started, fetched, completed, failed: window.studyGenericCrawler.activity()});
        """#, arguments: [:], in: nil, contentWorld: .page)
        let data = Data(try XCTUnwrap(value as? String).utf8)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String: Int]])
        XCTAssertEqual(result["started"], ["pending": 2, "completed": 0, "failed": 0])
        XCTAssertEqual(result["fetched"], ["pending": 1, "completed": 1, "failed": 0])
        XCTAssertEqual(result["completed"], ["pending": 0, "completed": 2, "failed": 0])
        XCTAssertEqual(result["failed"], ["pending": 0, "completed": 3, "failed": 1])
    }

    @MainActor
    func testXuechengCompleteReadingReplacesPartialImportState() throws {
        let lesson = WebCourseLesson(id: "generic:91:live:回放:0.0:0", name: "回放", subject: "", stage: "", chapter: "",
                                     kind: "living", published: true, durationSeconds: nil,
                                     watchedPercent: 0, markedFinished: false, requiresDuration: true)
        let page = "https://www.ixuecheng.cn/detail?id=91&type=1"
        let partial = WebCourseSnapshot(packageID: "generic:91", name: "回放课程", sourceURL: page,
                                        fetchedAt: Date(), expectedOutlines: 1, fetchedOutlines: 0,
                                        lessons: [lesson], issues: [])
        var timed = lesson
        timed.durationSeconds = 3060
        let complete = WebCourseSnapshot(packageID: partial.packageID, name: partial.name, sourceURL: page,
                                         fetchedAt: Date(), expectedOutlines: 1, fetchedOutlines: 1,
                                         lessons: [timed], issues: [])
        let merged = try XCTUnwrap(WebLessonReader.merged([partial], with: [complete]).first)
        XCTAssertEqual(merged.fetchedOutlines, 1)
        XCTAssertEqual(merged.lessons.first?.durationSeconds, 3060)
        XCTAssertNil(merged.importProblem)
    }

    @MainActor
    func testReplayMetadataMergesWithExistingProgressWithoutDuplicateLesson() throws {
        let old = WebCourseLesson(id: "generic:88:7", name: "阅读 T1+T2", subject: "", stage: "", chapter: "",
                                  kind: "video", published: true, durationSeconds: nil, watchedPercent: 35,
                                  markedFinished: false, requiresDuration: true)
        let replay = WebCourseLesson(id: "generic:88:live:阅读 T1+T2:1", name: "阅读 T1+T2", subject: "", stage: "", chapter: "",
                                     kind: "living", published: true, durationSeconds: 6420, watchedPercent: 0,
                                     markedFinished: false, requiresDuration: true)
        let base = WebCourseSnapshot(packageID: "generic:88", name: "章节", sourceURL: "https://ixuecheng.cn/api/course",
                                     fetchedAt: .distantPast, expectedOutlines: 1, fetchedOutlines: 1,
                                     lessons: [old], issues: [])
        let fresh = WebCourseSnapshot(packageID: "generic:88", name: "考研英语", sourceURL: "https://ixuecheng.cn/detail?id=88&type=1",
                                      fetchedAt: Date(), expectedOutlines: 1, fetchedOutlines: 1,
                                      lessons: [replay], issues: [])
        let combined = try XCTUnwrap(WebLessonReader.merged([base], with: [fresh]).first)
        XCTAssertEqual(combined.name, "考研英语")
        XCTAssertEqual(combined.lessons.count, 1)
        XCTAssertEqual(combined.lessons.first?.durationSeconds, 6420)
        XCTAssertEqual(combined.lessons.first?.watchedPercent, 35)
        XCTAssertNil(combined.importProblem)
    }

    @MainActor
    func testOffscreenReplayFrameReportsTimeWithoutPlaybackToken() async throws {
        let done = expectation(description: "replay metadata")
        let probe = ReplayProbe(done)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(probe, name: "replayMetadata")
        configuration.userContentController.addUserScript(WKUserScript(source: WebLessonReader.replayScript,
                                                                        injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        let replay = WKWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        replay.loadHTMLString("<html><body><div>阅读 T1+T2</div><div>直播时间：2026-07-29 14:57-16:44</div></body></html>",
                              baseURL: URL(string: "https://view.csslcloud.net/api/view/callback?recordid=temporary"))
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(probe.metadata?["title"] as? String, "阅读 T1+T2")
        XCTAssertEqual(probe.metadata?["durationSeconds"] as? Double, 6420)
        XCTAssertNil(probe.metadata?["url"])
        replay.stopLoading()
        configuration.userContentController.removeScriptMessageHandler(forName: "replayMetadata")
    }
}
