import Testing
import Foundation

@Suite("LivelyInfoParser") struct LivelyInfoParserTests {
    let parser = LivelyInfoParser()

    private func data(_ json: String) -> Data { json.data(using: .utf8)! }

    @Test func parsesBasicStringFields() throws {
        let info = try #require(parser.parse(from: data("""
        {"Type":"web","Title":"My Wallpaper","Author":"Jane","FileName":"index.html"}
        """)))
        #expect(info.type == "web")
        #expect(info.Title == "My Wallpaper")
        #expect(info.Author == "Jane")
        #expect(info.FileName == "index.html")
    }

    @Test func parsesTypeIntWeb() throws {
        let info = try #require(parser.parse(from: data(#"{"Type":1}"#)))
        #expect(info.type == "web")
    }

    @Test func parsesTypeIntVideo() throws {
        let info = try #require(parser.parse(from: data(#"{"Type":2}"#)))
        #expect(info.type == "video")
    }

    @Test func parsesTypeIntApp() throws {
        let info = try #require(parser.parse(from: data(#"{"Type":3}"#)))
        #expect(info.type == "app")
    }

    @Test func parsesUnknownIntTypeAsString() throws {
        let info = try #require(parser.parse(from: data(#"{"Type":99}"#)))
        #expect(info.type == "99")
    }

    @Test func parsesDescFallback() throws {
        let info = try #require(parser.parse(from: data(#"{"Desc":"Fallback desc"}"#)))
        #expect(info.Description == "Fallback desc")
    }

    @Test func prefersDescriptionOverDesc() throws {
        let info = try #require(parser.parse(from: data(#"{"Description":"Primary","Desc":"Fallback"}"#)))
        #expect(info.Description == "Primary")
    }

    @Test func parsesPreviewField() throws {
        let info = try #require(parser.parse(from: data(#"{"Preview":"preview.gif"}"#)))
        #expect(info.Preview == "preview.gif")
    }

    @Test func parsesTagsArray() throws {
        let info = try #require(parser.parse(from: data(#"{"Tags":["nature","animated"]}"#)))
        #expect(info.Tags == ["nature", "animated"])
    }

    @Test func returnsNilForEmptyData() {
        #expect(parser.parse(from: Data()) == nil)
    }

    @Test func returnsNilForInvalidJSON() {
        #expect(parser.parse(from: data("not json at all")) == nil)
    }

    @Test func allFieldsOptional_emptyObjectParsesOk() throws {
        let info = try #require(parser.parse(from: data("{}")))
        #expect(info.type == nil)
        #expect(info.Title == nil)
    }
}
