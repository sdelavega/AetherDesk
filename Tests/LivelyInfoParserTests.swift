// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stephen de la Vega. All rights reserved.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

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
