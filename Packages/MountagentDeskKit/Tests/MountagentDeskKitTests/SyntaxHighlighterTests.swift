import Foundation
import Testing
@testable import MountagentDeskKit

@Suite struct SyntaxHighlighterTests {
    private func tokens(_ text: String, _ language: CodeLanguage) -> [String: SyntaxHighlighter.Token] {
        let ns = text as NSString
        var result: [String: SyntaxHighlighter.Token] = [:]
        for span in SyntaxHighlighter.spans(in: text, language: language) {
            result[ns.substring(with: span.range)] = span.token
        }
        return result
    }

    @Test func picksLanguagesByName() {
        #expect(CodeLanguage(fileName: "stock_location.py") == .python)
        #expect(CodeLanguage(fileName: "views.XML") == .xml)
        #expect(CodeLanguage(fileName: "Dockerfile") == .shell)
        #expect(CodeLanguage(fileName: "notes.txt") == .plain)
    }

    @Test func colorsPython() {
        let code = """
        @api.model
        def get_view(self, view_id=None):  # see "docs"
            \"\"\"Doc with # inside.\"\"\"
            return 'x#y' if view_id else 42
        class StockLocation(models.Model):
        """
        let found = tokens(code, .python)
        #expect(found["@api.model"] == .decorator)
        #expect(found["def"] == .keyword)
        #expect(found["get_view"] == .function)
        #expect(found["self"] == .constant)
        #expect(found["None"] == .constant)
        #expect(found["# see \"docs\""] == .comment)
        #expect(found["\"\"\"Doc with # inside.\"\"\""] == .string)
        #expect(found["'x#y'"] == .string)
        #expect(found["42"] == .number)
        #expect(found["StockLocation"] == .type)
        #expect(found["docs"] == nil, "nothing inside a comment is colored again")
    }

    @Test func colorsOdooXML() {
        let code = #"<field name="barcode" readonly="1"/> <!-- note -->"#
        let found = tokens(code, .xml)
        #expect(found["field"] == .tag)
        #expect(found["name"] == .attribute)
        #expect(found["\"barcode\""] == .string)
        #expect(found["<!-- note -->"] == .comment)
    }

    @Test func colorsJSONKeysAndValues() {
        let found = tokens(#"{"name": "Mountagent Desk", "count": 3, "on": true}"#, .json)
        #expect(found["\"name\""] == .property)
        #expect(found["\"Mountagent Desk\""] == .string)
        #expect(found["3"] == .number)
        #expect(found["true"] == .constant)
    }

    @Test func everyGrammarCompiles() {
        for language in CodeLanguage.allCases {
            _ = SyntaxHighlighter.spans(in: "x = 1 # y \"z\"", language: language)
        }
    }
}
