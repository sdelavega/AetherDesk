import Testing
import Foundation

@Suite("LivelyPropertiesParser") struct LivelyPropertiesParserTests {
    let parser = LivelyPropertiesParser()

    private func data(_ json: String) -> Data { json.data(using: .utf8)! }

    // MARK: Array format

    @Test func parsesArrayFormat() throws {
        let props = try #require(parser.parse(from: data("""
        {"properties":[{"Name":"speed","Type":"slider","Value":50}]}
        """)))
        #expect(props.count == 1)
        #expect(props[0].name == "speed")
        #expect(props[0].value.intValue == 50)
    }

    @Test func parsesArrayFormatWithMinMax() throws {
        let props = try #require(parser.parse(from: data("""
        {"properties":[{"Name":"n","Type":"range","Value":50,"Min":0,"Max":100,"Increment":5}]}
        """)))
        #expect(props[0].min?.intValue == 0)
        #expect(props[0].max?.intValue == 100)
        #expect(props[0].increment == 5.0)
    }

    @Test func parsesArrayFormatBoolProperty() throws {
        let props = try #require(parser.parse(from: data("""
        {"properties":[{"Name":"enabled","Type":"bool","Value":true}]}
        """)))
        #expect(props[0].value.boolValue == true)
    }

    @Test func parsesArrayFormatColorProperty() throws {
        let props = try #require(parser.parse(from: data("""
        {"properties":[{"Name":"tint","Type":"color","Value":"#ff0000"}]}
        """)))
        #expect(props[0].value.stringValue == "#ff0000")
    }

    // MARK: Per-key format

    @Test func parsesPerKeyFormat() throws {
        let props = try #require(parser.parse(from: data("""
        {"speed":{"type":"slider","value":30,"text":"Speed control","min":0,"max":100}}
        """)))
        #expect(props.count == 1)
        #expect(props[0].name == "speed")
        #expect(props[0].description == "Speed control")
        #expect(props[0].value.intValue == 30)
    }

    @Test func parsesPerKeyFormatMultipleKeys() throws {
        let props = try #require(parser.parse(from: data("""
        {"speed":{"type":"slider","value":30},"enabled":{"type":"bool","value":true}}
        """)))
        #expect(props.count == 2)
    }

    // MARK: PropertyType normalization

    @Test func sliderNormalizesToRange() {
        #expect(PropertyType(from: "slider") == .range)
    }

    @Test func sliderCaseInsensitive() {
        #expect(PropertyType(from: "Slider") == .range)
        #expect(PropertyType(from: "SLIDER") == .range)
    }

    @Test func boolCaseInsensitive() {
        #expect(PropertyType(from: "BOOL") == .bool)
        #expect(PropertyType(from: "Bool") == .bool)
    }

    @Test func colorCaseInsensitive() {
        #expect(PropertyType(from: "Color") == .color)
    }

    @Test func unknownTypeIsUnknown() {
        #expect(PropertyType(from: "mystery") == .unknown)
        #expect(PropertyType(from: "") == .unknown)
    }

    // MARK: AnyCodableValue

    @Test func anyCodableIntValue() throws {
        let props = try #require(parser.parse(from: data("""
        {"properties":[{"Name":"n","Type":"range","Value":42}]}
        """)))
        #expect(props[0].value.intValue == 42)
        #expect(props[0].value.doubleValue == 42.0)
        #expect(props[0].value.stringValue == nil)
    }

    @Test func anyCodableDoubleValue() throws {
        let props = try #require(parser.parse(from: data("""
        {"properties":[{"Name":"n","Type":"range","Value":3.14}]}
        """)))
        #expect(props[0].value.intValue == nil)
        let d = try #require(props[0].value.doubleValue)
        #expect(abs(d - 3.14) < 0.001)
    }

    @Test func anyCodableStringValue() throws {
        let props = try #require(parser.parse(from: data("""
        {"properties":[{"Name":"c","Type":"color","Value":"#00ff00"}]}
        """)))
        #expect(props[0].value.stringValue == "#00ff00")
        #expect(props[0].value.boolValue == nil)
    }

    @Test func anyCodableBoolValue() throws {
        let props = try #require(parser.parse(from: data("""
        {"properties":[{"Name":"f","Type":"bool","Value":false}]}
        """)))
        #expect(props[0].value.boolValue == false)
    }

    @Test func returnsNilForInvalidJSON() {
        #expect(parser.parse(from: "bad".data(using: .utf8)!) == nil)
    }

    @Test func returnsNilForEmptyData() {
        #expect(parser.parse(from: Data()) == nil)
    }
}
