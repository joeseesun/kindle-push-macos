import XCTest
@testable import KindlePush

@MainActor
final class StoreTests: XCTestCase {
    private func book(_ path: String, language: String? = "en", canTranslate: Bool? = true, status: String = "等待发送") -> Article {
        var article = Article(path: path)
        article.language = language; article.canTranslate = canTranslate; article.status = status
        return article
    }

    override func setUp() { I18n.english = false }

    func testOnlyReadableBooksWithAKnownLanguageCanBeTranslated() {
        let store = PushStore()
        XCTAssertTrue(store.translatable(book("/x/a.txt")))
        XCTAssertFalse(store.translatable(book("/x/a.pdf", canTranslate: false)))
        XCTAssertFalse(store.translatable(book("/x/a.epub", language: nil)))
        // Kept from before 1.15, not yet read again: only EPUB was translatable then.
        XCTAssertTrue(store.translatable(book("/x/a.epub", canTranslate: nil)))
        XCTAssertFalse(store.translatable(book("/x/a.docx", canTranslate: nil)))
    }

    func testABookIsNeverTranslatedIntoItsOwnLanguage() {
        let store = PushStore()
        var chinese = book("/x/a.epub", language: "zh")
        chinese.choice = .bilingual; chinese.target = "zh"
        XCTAssertEqual(store.mode(of: chinese), .original)
        chinese.target = "en"
        XCTAssertEqual(store.mode(of: chinese), .bilingual)
    }

    func testRemoveCanBeUndoneInPlace() {
        let store = PushStore()
        let items = ["/x/1.epub", "/x/2.epub", "/x/3.epub", "/x/4.epub"].map { book($0) }
        store.articles = items
        store.remove([items[0].id, items[2].id])
        XCTAssertEqual(store.articles.map(\.path), ["/x/2.epub", "/x/4.epub"])
        XCTAssertEqual(store.undoable.count, 2)
        store.undoRemove()
        XCTAssertEqual(store.articles.map(\.path), items.map(\.path))
        XCTAssertTrue(store.undoable.isEmpty)
    }

    func testABookInFlightIsNotRemoved() {
        let store = PushStore()
        let busy = book("/x/1.epub", status: "发送中")
        store.articles = [busy]
        store.quick.running = true
        store.remove([busy.id])
        XCTAssertEqual(store.articles.count, 1)
        XCTAssertTrue(store.undoable.isEmpty)
        store.quick.running = false
    }

    func testEachQueueTracksItsOwnTransfer() {
        let store = PushStore()
        let id = UUID()
        store.translation.sending = id
        XCTAssertNil(store.quick.sending, "取消这本 only acts on the send queue's own book")
    }

    func testEstimates() {
        let store = PushStore()
        var chosen = book("/x/a.epub")
        chosen.choice = .bilingual; chosen.target = "zh"; chosen.textSize = 1_000_000
        store.articles = [chosen]
        XCTAssertEqual(store.translationTokens, 600_000)
        store.articles = [book("/x/a.epub")]
        XCTAssertNil(store.translationTokens)
    }

    func testTokenText() {
        I18n.english = false
        XCTAssertEqual(PushStore.tokenText(411), "411")
        XCTAssertEqual(PushStore.tokenText(12_300), "1.2 万")
        XCTAssertEqual(PushStore.tokenText(611_000), "61 万")
        XCTAssertEqual(PushStore.tokenText(1_260_000), "126 万")
    }

    func testPhases() {
        XCTAssertEqual(book("/x/a", status: "翻译中").phase, .working)
        XCTAssertEqual(book("/x/a", status: "失败").phase, .failed)
        XCTAssertEqual(book("/x/a", status: "已发送").phase, .done)
        XCTAssertEqual(book("/x/a", status: "翻译完成").phase, .ready)
    }

    func testOldSavedListsStillDecode() throws {
        let saved = #"[{"id":"7D444840-9DC0-11D1-B245-5FFDCE74FAD2","path":"/x/a.epub","status":"等待发送","details":""}]"#
        let list = try JSONDecoder().decode([Article].self, from: Data(saved.utf8))
        XCTAssertNil(list[0].canTranslate)
        XCTAssertNil(list[0].tokens)
    }

    func testSupportedFormatsMatchTheBridge() {
        for name in ["a.epub", "a.txt", "a.md", "a.docx", "a.pdf", "a.mobi", "a.fb2"] {
            XCTAssertTrue(Article.isSupported(URL(fileURLWithPath: "/x/" + name)), name)
        }
        XCTAssertFalse(Article.isSupported(URL(fileURLWithPath: "/x/a.exe")))
    }

    // MARK: English

    private func catalog() throws -> ([String: String], [(NSRegularExpression, String)]) {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Assets/i18n/en.tsv")
        return I18n.parse(try String(contentsOf: url, encoding: .utf8))
    }

    func testEnglishFillsTemplatesAndTranslatesWhatIsFilledIn() throws {
        let (exact, templates) = try catalog()
        func en(_ text: String) -> String { I18n.translate(text, exact: exact, templates: templates) }
        XCTAssertEqual(en("重试"), "Retry")
        XCTAssertEqual(en("已移除 3 本"), "Removed 3 books")
        XCTAssertEqual(en("已移除《Snow Crash》"), "Removed “Snow Crash”")
        XCTAssertEqual(en("仅英文"), "English only")
        XCTAssertEqual(en("正在翻译 · 42%"), "Translating · 42%")
        XCTAssertEqual(en("正在翻译 · 42% · 还剩约 5 分钟"), "Translating · 42% · About 5 min left")
        XCTAssertEqual(en("Snow Crash.epub"), "Snow Crash.epub")
    }

    func testSentencesThisAppJoinsAreTranslatedPiecewise() throws {
        let (exact, templates) = try catalog()
        func en(_ text: String) -> String { I18n.translate(text, exact: exact, templates: templates) }
        XCTAssertEqual(en("2 篇未完成，可以重试；1 个文件已保存到本机，已在访达中选中。"),
                       "2 not finished, you can retry; 1 file(s) saved to this Mac and selected in Finder.")
        XCTAssertEqual(en("已发到 甲；「乙」不在这个 Wi-Fi 里。重试只发给没收到的"),
                       "Sent to 甲; “乙” is not on this Wi-Fi. Retry sends only to those that didn't get it")
    }

    func testChineseStaysChineseWhenThatIsTheLanguage() {
        I18n.english = false
        XCTAssertEqual(t("重试"), "重试")
    }

    func testEnglishLabels() {
        I18n.english = true; defer { I18n.english = false }
        XCTAssertEqual(PushStore.tokenText(611_000), "611k")
        XCTAssertEqual(PushStore.tokenText(1_260_000), "1.3M")
    }
}
