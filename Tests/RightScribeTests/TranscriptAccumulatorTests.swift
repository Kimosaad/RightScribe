import XCTest
import CoreGraphics
@testable import RightScribe

final class TranscriptAccumulatorTests: XCTestCase {
    func testKeyboardListenerIsPassiveAndCannotConsumeKeystrokes() {
        XCTAssertEqual(
            RightCommandMonitor.tapOptions.rawValue,
            CGEventTapOptions.listenOnly.rawValue
        )
    }

    func testFinalAndVolatileSegmentsRemainReadable() {
        var accumulator = TranscriptAccumulator()
        accumulator.receive("Hello", isFinal: true)
        accumulator.receive("world", isFinal: false)
        XCTAssertEqual(accumulator.displayText, "Hello world")

        accumulator.receive("world.", isFinal: true)
        XCTAssertEqual(accumulator.displayText, "Hello world.")
        XCTAssertEqual(accumulator.finalized, "Hello world.")
    }

    func testPunctuationDoesNotGainLeadingSpace() {
        XCTAssertEqual(TranscriptAccumulator.join("Hello", ", world"), "Hello, world")
    }

    func testV1RouterAlwaysInsertsText() async {
        let route = await V1TranscriptRouter().route("Create a reminder")
        XCTAssertEqual(route, .insertText("Create a reminder"))
    }

    func testRightCommandPressTogglesOnRelease() {
        var gesture = RightCommandGestureInterpreter()
        XCTAssertNil(gesture.handleRightCommand(isDown: true))
        XCTAssertEqual(gesture.handleRightCommand(isDown: false), .toggle)
    }

    func testCommandChordDoesNotToggleOnRelease() {
        var gesture = RightCommandGestureInterpreter()
        XCTAssertNil(gesture.handleRightCommand(isDown: true))
        XCTAssertEqual(gesture.handleOtherInput(), .chord)
        XCTAssertNil(gesture.handleRightCommand(isDown: false))
    }

    func testConsumedRightCommandDownDoesNotToggleAgainOnRelease() {
        var gesture = RightCommandGestureInterpreter()
        XCTAssertNil(gesture.handleRightCommand(isDown: true))
        gesture.consumeCurrentPress()
        XCTAssertNil(gesture.handleRightCommand(isDown: false))
    }

    func testRepeatedModifierEventsDoNotDoubleToggle() {
        var gesture = RightCommandGestureInterpreter()
        XCTAssertNil(gesture.handleRightCommand(isDown: true))
        XCTAssertNil(gesture.handleRightCommand(isDown: true))
        XCTAssertEqual(gesture.handleRightCommand(isDown: false), .toggle)
        XCTAssertNil(gesture.handleRightCommand(isDown: false))
    }

    func testFillerWordsAreRemovedAndSpacingIsRepaired() {
        XCTAssertEqual(
            TranscriptCleaner.removingFillers(from: "Um, I think, you know, this works."),
            "I think this works."
        )
    }

    func testMeaningfulLikeAndYouKnowArePreserved() {
        XCTAssertEqual(
            TranscriptCleaner.removingFillers(from: "The small like wave icon works."),
            "The small like wave icon works."
        )
        XCTAssertEqual(
            TranscriptCleaner.removingFillers(from: "Do you know where it is?"),
            "Do you know where it is?"
        )
    }

    func testLeadingLikeWithCommaIsRemoved() {
        XCTAssertEqual(
            TranscriptCleaner.removingFillers(from: "Like, can we move it?"),
            "Can we move it?"
        )
    }

    func testTranscriptHistoryItemRoundTripsThroughJSON() throws {
        let item = TranscriptHistoryItem(
            id: UUID(),
            text: "A saved transcript",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            applicationName: "Notes"
        )
        let data = try JSONEncoder().encode(item)
        XCTAssertEqual(try JSONDecoder().decode(TranscriptHistoryItem.self, from: data), item)
    }

    func testCustomVocabularyNormalizesWhitespaceAndRejectsDuplicates() {
        var entries = CustomVocabulary.adding("  Canary   Quinn\n", to: [])
        XCTAssertEqual(entries, ["Canary Quinn"])
        entries = CustomVocabulary.adding("canary quinn", to: entries)
        XCTAssertEqual(entries, ["Canary Quinn"])
    }

    func testCustomVocabularyHonorsApplePhraseLimit() {
        let entries = (0..<CustomVocabulary.maximumEntryCount).map { "Term \($0)" }
        XCTAssertEqual(
            CustomVocabulary.adding("One too many", to: entries),
            entries
        )
    }

    func testMeetingRecordRoundTripsThroughJSON() throws {
        let calendarEvent = CalendarEventSnapshot(
            provider: "Google Calendar",
            eventIdentifier: "event-123",
            title: "Product review",
            calendarIdentifier: "primary",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_900),
            meetingURL: "https://meet.google.com/abc-defg-hij",
            organizerEmail: "organizer@example.com",
            attendees: [
                CalendarAttendeeSnapshot(
                    name: "Ada Lovelace",
                    email: "ada@example.com",
                    responseStatus: "accepted",
                    isOrganizer: false,
                    isSelf: false
                )
            ]
        )
        let meeting = MeetingRecord(
            id: UUID(),
            title: "Product review",
            sourceApplication: "Zoom",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_900),
            turns: [
                MeetingTranscriptTurn(
                    id: UUID(),
                    speaker: .you,
                    text: "Let's begin.",
                    startedAt: 1
                ),
                MeetingTranscriptTurn(
                    id: UUID(),
                    speaker: .attendee,
                    text: "Sounds good.",
                    startedAt: 2
                )
            ],
            calendarEvent: calendarEvent
        )
        let data = try JSONEncoder().encode(meeting)
        XCTAssertEqual(try JSONDecoder().decode(MeetingRecord.self, from: data), meeting)
        XCTAssertEqual(meeting.fullTranscript, "You: Let's begin.\n\nAttendee: Sounds good.")
    }

    func testOldMeetingHistoryWithoutCalendarEventStillDecodes() throws {
        let json = """
        {
          "id":"00000000-0000-0000-0000-000000000001",
          "title":"Old meeting",
          "sourceApplication":"Zoom",
          "startedAt":0,
          "endedAt":60,
          "turns":[]
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let meeting = try decoder.decode(MeetingRecord.self, from: json)
        XCTAssertNil(meeting.calendarEvent)
    }

    func testGoogleCalendarMatchingPrefersActiveEventForMeetingApp() throws {
        let json = """
        [
          {
            "id":"earlier",
            "status":"confirmed",
            "summary":"Earlier call",
            "start":{"dateTime":"2026-08-25T13:00:00Z"},
            "end":{"dateTime":"2026-08-25T13:30:00Z"}
          },
          {
            "id":"current",
            "status":"confirmed",
            "summary":"Fundraising update",
            "description":"Join at https://zoom.us/j/123456",
            "start":{"dateTime":"2026-08-25T14:00:00.000Z"},
            "end":{"dateTime":"2026-08-25T15:00:00Z"},
            "organizer":{"email":"founder@example.com"},
            "attendees":[
              {"email":"me@example.com","self":true,"responseStatus":"accepted"},
              {"email":"investor@example.com","displayName":"Grace Hopper","responseStatus":"accepted"}
            ]
          }
        ]
        """.data(using: .utf8)!
        let events = try JSONDecoder().decode([GoogleCalendarEvent].self, from: json)
        let date = ISO8601DateFormatter().date(from: "2026-08-25T14:10:00Z")!

        let match = GoogleCalendarService.bestMatch(in: events, at: date, meetingFamily: "zoom")

        XCTAssertEqual(match?.title, "Fundraising update")
        XCTAssertEqual(match?.organizerEmail, "founder@example.com")
        XCTAssertEqual(match?.attendees.last?.displayName, "Grace Hopper")
        XCTAssertEqual(match?.meetingURL, "https://zoom.us/j/123456")
    }

    func testMeetingTurnsMergeChronologicallyAndCoalesceSameSpeaker() {
        let youFirst = MeetingTranscriptTurn(
            id: UUID(), speaker: .you, text: "Hello", startedAt: 1
        )
        let youSecond = MeetingTranscriptTurn(
            id: UUID(), speaker: .you, text: "everyone.", startedAt: 3
        )
        let attendee = MeetingTranscriptTurn(
            id: UUID(), speaker: .attendee, text: "Hi there.", startedAt: 8
        )

        let merged = MeetingTranscriptMerger.merged([attendee, youSecond, youFirst])

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].speaker, .you)
        XCTAssertEqual(merged[0].text, "Hello everyone.")
        XCTAssertEqual(merged[1].speaker, .attendee)
    }

    func testMeetingEndGraceExpiresAndReturnsNoCandidate() {
        var tracker = MeetingEndGraceTracker()
        let candidate = MeetingCandidate(
            processID: 42,
            applicationName: "zoom.us",
            bundleIdentifier: "us.zoom.xos",
            applicationFamily: "zoom"
        )
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(
            tracker.resolvedCandidate(
                detected: nil,
                current: candidate,
                hasMeetingWindow: false,
                now: start
            ),
            candidate
        )
        XCTAssertEqual(
            tracker.resolvedCandidate(
                detected: nil,
                current: candidate,
                hasMeetingWindow: false,
                now: start.addingTimeInterval(11)
            ),
            candidate
        )
        XCTAssertNil(
            tracker.resolvedCandidate(
                detected: nil,
                current: candidate,
                hasMeetingWindow: false,
                now: start.addingTimeInterval(12)
            )
        )
    }

    func testMeetingEndGraceResetsWhenCallActivityReturns() {
        var tracker = MeetingEndGraceTracker()
        let candidate = MeetingCandidate(
            processID: 42,
            applicationName: "zoom.us",
            bundleIdentifier: "us.zoom.xos",
            applicationFamily: "zoom"
        )
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = tracker.resolvedCandidate(
            detected: nil,
            current: candidate,
            hasMeetingWindow: false,
            now: start
        )

        XCTAssertEqual(
            tracker.resolvedCandidate(
                detected: candidate,
                current: candidate,
                hasMeetingWindow: false,
                now: start.addingTimeInterval(8)
            ),
            candidate
        )
        XCTAssertNil(tracker.missingSince)
    }
}
