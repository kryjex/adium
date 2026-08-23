import Testing
import Foundation
@testable import Fluorite

/// These tests cover the Teams call link detection and construction.
/// The URL construction mirrors the /call command of purple-teams.
@Suite("Teams Call Link Detection")
struct TeamsCallLinkTests {

    // MARK: - Meeting link detection in message text

    @Test("Detects a plain meetup-join link in message text")
    func testDetectsPlainMeetupJoinLink() {
        let text = "Únete aquí: https://teams.microsoft.com/l/meetup-join/19%3ameeting_ABC123%40thread.v2/0?context=%7b%22Tid%22%3a%22guid%22%7d y no llegues tarde"
        let url = TeamsCallLink.meetingURL(in: text)
        #expect(url != nil)
        #expect(url?.host == "teams.microsoft.com")
        #expect(url?.path.hasPrefix("/l/meetup-join/") == true)
    }

    @Test("Detects a meetup-join link inside an HTML href attribute")
    func testDetectsLinkInsideHTML() {
        let text = "<a href=\"https://teams.microsoft.com/l/meetup-join/19%3aabc%40thread.v2/0\">Join meeting</a>"
        let url = TeamsCallLink.meetingURL(in: text)
        #expect(url?.absoluteString == "https://teams.microsoft.com/l/meetup-join/19%3aabc%40thread.v2/0")
    }

    @Test("Detects a personal teams.live.com meeting link")
    func testDetectsTeamsLiveLink() {
        let text = "https://teams.live.com/meet/9351234567890"
        #expect(TeamsCallLink.meetingURL(in: text)?.host == "teams.live.com")
    }

    @Test("Ignores text without meeting links")
    func testIgnoresPlainText() {
        #expect(TeamsCallLink.meetingURL(in: "hola, ¿comemos a las 2?") == nil)
        #expect(TeamsCallLink.meetingURL(in: "https://teams.microsoft.com/otracosa") == nil)
        #expect(TeamsCallLink.meetingURL(in: "") == nil)
    }

    @Test("Link detection stops at whitespace and quotes")
    func testLinkBoundaries() {
        let text = "https://teams.microsoft.com/l/meetup-join/19%3aabc%40thread.v2/0 siguiente palabra"
        #expect(TeamsCallLink.meetingURL(in: text)?.absoluteString == "https://teams.microsoft.com/l/meetup-join/19%3aabc%40thread.v2/0")
    }

    // MARK: - Call event system messages from purple-teams

    @Test("Recognizes the call notices written by teams_trouter.c")
    func testRecognizesCallEventMessages() {
        #expect(TeamsCallLink.isCallEventMessage("Incoming call"))
        #expect(TeamsCallLink.isCallEventMessage("Outgoing call"))
        #expect(!TeamsCallLink.isCallEventMessage("Incoming call from Bob"))
        #expect(!TeamsCallLink.isCallEventMessage("hola"))
    }

    // MARK: - Join URL construction from conversation handles

    @Test("Builds a meetup-join URL from a thread handle like /call does")
    func testBuildsURLFromThreadHandle() {
        let url = TeamsCallLink.meetingURL(forThreadHandle: "19:meeting_ABC123@thread.v2")
        #expect(url?.absoluteString == "https://teams.microsoft.com/l/meetup-join/19%3Ameeting%5FABC123%40thread%2Ev2/0")
    }

    @Test("Refuses to build a URL from a buddy handle")
    func testRefusesBuddyHandle() {
        // A buddy id is not a thread; the plugin resolves it via buddy_to_chat_lookup.
        #expect(TeamsCallLink.meetingURL(forThreadHandle: "orgid:12345678-abcd-ef01-2345-6789abcdef01") == nil)
        #expect(TeamsCallLink.meetingURL(forThreadHandle: "") == nil)
    }

    // MARK: - Media capture origin allowlist

    @Test("Grants capture only to Microsoft call/auth origins")
    func testTrustedCallHosts() {
        #expect(TeamsCallLink.isTrustedCallHost("teams.microsoft.com"))
        #expect(TeamsCallLink.isTrustedCallHost("teams.live.com"))
        #expect(TeamsCallLink.isTrustedCallHost("login.microsoftonline.com"))
        #expect(!TeamsCallLink.isTrustedCallHost("evil-teams.microsoft.com.attacker.example"))
        #expect(!TeamsCallLink.isTrustedCallHost("example.com"))
        #expect(!TeamsCallLink.isTrustedCallHost(nil))
    }
}
