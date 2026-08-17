import Foundation
@testable import Moblin
import Testing

// The dashboard writes this JSON by hand, so the wire shape is part of the
// contract rather than an implementation detail. A rename on this side that
// nobody notices turns every director message into a silent no-op: an
// undecodable request is caught and logged, and no response is ever sent, so
// the dashboard sees a request that simply never comes back.
struct RemoteControlShowMessageSuite {
    private func decodeShowMessage(_ json: String) throws -> (String, Double?) {
        let message = try RemoteControlMessageToStreamer.fromJson(data: json)
        guard case let .request(id: _, data: data) = message,
              case let .showMessage(message: text, durationSeconds: duration) = data
        else {
            throw "Not a showMessage request: \(message)"
        }
        return (text, duration)
    }

    @Test func decodesTheDocumentedShape() throws {
        let (text, duration) = try decodeShowMessage("""
        {"request":{"id":7,"data":{"showMessage":{"message":"Move left","durationSeconds":8}}}}
        """)
        #expect(text == "Move left")
        #expect(duration == 8)
    }

    // Absent is not zero. A dashboard that omits the field wants the app's
    // default, and a flash of one frame would read as the message never
    // arriving.
    @Test func durationIsOptional() throws {
        let (text, duration) = try decodeShowMessage("""
        {"request":{"id":7,"data":{"showMessage":{"message":"Battery low"}}}}
        """)
        #expect(text == "Battery low")
        #expect(duration == nil)
    }

    @Test func keepsNonAsciiIntact() throws {
        let (text, _) = try decodeShowMessage("""
        {"request":{"id":7,"data":{"showMessage":{"message":"往左移一點"}}}}
        """)
        #expect(text == "往左移一點")
    }

    @Test func roundTrips() throws {
        let sent = RemoteControlMessageToStreamer.request(
            id: 7,
            data: .showMessage(message: "Standby", durationSeconds: 3)
        )
        let json = try #require(sent.toJson())
        let (text, duration) = try decodeShowMessage(json)
        #expect(text == "Standby")
        #expect(duration == 3)
    }

    // The response carries whether anybody could have read it, so the director
    // is not left assuming a phone in a pocket got the instruction.
    @Test func responseReportsWhetherItWasSeen() throws {
        let sent = RemoteControlMessageToAssistant.response(
            id: 7,
            result: .ok,
            data: .showMessage(displayed: false)
        )
        let message = try RemoteControlMessageToAssistant.fromJson(data: sent.toJson())
        guard case let .response(id: id, result: _, data: data) = message,
              case let .showMessage(displayed: displayed) = data
        else {
            throw "Not a showMessage response: \(message)"
        }
        #expect(id == 7)
        #expect(displayed == false)
    }
}
