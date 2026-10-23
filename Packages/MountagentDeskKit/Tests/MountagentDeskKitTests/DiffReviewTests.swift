import Foundation
import Testing
@testable import MountagentDeskKit

@Suite struct DiffReviewTests {
    let diff = """
    diff --git a/app.py b/app.py
    index 1..2 100644
    --- a/app.py
    +++ b/app.py
    @@ -10,3 +10,4 @@ def status():
         if rain > 30:
    -        return 'closed'
    +        return "closed"
    +    log(rain)
         return 'open'

    """

    @Test func numbersEachLine() {
        let lines = DiffReview.lines(of: diff)
        #expect(lines.map(\.kind) == [.hunk, .context, .removed, .added, .added, .context])
        #expect(lines[1].oldNumber == 10 && lines[1].newNumber == 10)
        #expect(lines[2].oldNumber == 11 && lines[2].newNumber == nil)
        #expect(lines[3].newNumber == 11 && lines[4].newNumber == 12)
        #expect(lines[5].oldNumber == 12 && lines[5].newNumber == 13)
    }

    @Test func groupsCommentsIntoOneMessage() {
        let message = DiffReview.message(for: [
            .init(path: "b.py", line: 4, removed: false, code: "+x = 1", text: "Name it count"),
            .init(path: "app.py", line: 12, removed: false, code: "+    log(rain)", text: "Use the logger"),
            .init(path: "app.py", line: 11, removed: true, code: "-        return 'closed'", text: "Keep single quotes"),
        ])
        #expect(message == """
        Review comments on your uncommitted changes. Address each one:

        `app.py`
        - removed line 11 (`return 'closed'`): Keep single quotes
        - line 12 (`log(rain)`): Use the logger

        `b.py`
        - line 4 (`x = 1`): Name it count
        """)
    }
}
