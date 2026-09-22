import Foundation
import CoreLocation
import FirebaseAuth
import FirebaseAppCheck

/// An event from the streaming guide endpoint.
enum ContentEvent {
    case partial(PartialPlaceContent)   // growing snapshot
    case complete(PlaceContent)         // final doc (also cached server-side)
}

/// Calls our backend `getPlaceContent` function, which returns cached content or
/// generates it on a cache miss. The OpenAI key lives only on the backend.
///
/// Every request carries a Firebase ID token (+ App Check token) so the backend can attribute it to
/// a user and enforce the free tier. The server's metering replies map to typed errors:
///   401 → unauthorized, 402 → freeLimitReached (paywall), 429 → rateLimited.
struct ContentService {
    enum ContentError: Error { case unauthorized, freeLimitReached, rateLimited, badResponse }

    private static func statusError(_ code: Int) -> ContentError {
        switch code {
        case 401: return .unauthorized
        case 402: return .freeLimitReached
        case 429: return .rateLimited
        default:  return .badResponse
        }
    }

    /// Auth + App Check headers for an outbound request. Signs in anonymously first if needed.
    private func authHeaders() async -> [String: String] {
        if Auth.auth().currentUser == nil { _ = try? await Auth.auth().signInAnonymously() }
        var headers: [String: String] = [:]
        if let token = try? await Auth.auth().currentUser?.getIDToken() {
            headers["Authorization"] = "Bearer \(token)"
        }
        if let appCheck = try? await AppCheck.appCheck().token(forcingRefresh: false) {
            headers["X-Firebase-AppCheck"] = appCheck.token
        }
        return headers
    }

    /// The device's UTC offset in minutes — the backend derives the user's local day from this
    /// (rather than trusting the device clock) for the free "active days" gate.
    private var tzOffsetMinutes: Int { TimeZone.current.secondsFromGMT() / 60 }

    private func payload(for place: Place, locality: String?) -> [String: Any] {
        [
            "place_id": place.id,
            "name": place.name,
            "types": place.types,
            "lat": place.coordinate.latitude,
            "lng": place.coordinate.longitude,
            "locality": locality ?? "",
            "tz_offset_minutes": tzOffsetMinutes,
        ]
    }

    func content(for place: Place, locality: String?) async throws -> PlaceContent {
        let url = URL(string: Secrets.backendURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        for (k, v) in await authHeaders() { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload(for: place, locality: locality))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ContentError.badResponse }
        guard http.statusCode == 200 else { throw Self.statusError(http.statusCode) }

        return try JSONDecoder().decode(ContentResponse.self, from: data).content
    }

    /// Streams the guide via SSE: yields `.partial` snapshots as the model generates, then a
    /// final `.complete`. Cache hits yield a single `.complete` quickly.
    func stream(for place: Place, locality: String?) -> AsyncThrowingStream<ContentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = URL(string: Secrets.backendStreamURL)!
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.timeoutInterval = 120
                    for (k, v) in await authHeaders() { request.setValue(v, forHTTPHeaderField: k) }
                    request.httpBody = try JSONSerialization.data(withJSONObject: payload(for: place, locality: locality))

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw ContentError.badResponse }
                    guard http.statusCode == 200 else { throw Self.statusError(http.statusCode) }
                    let decoder = JSONDecoder()
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let data = json.data(using: .utf8),
                              let type = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["type"] as? String
                        else { continue }
                        switch type {
                        case "partial":
                            if let env = try? decoder.decode(PartialEnvelope.self, from: data) {
                                continuation.yield(.partial(env.content))
                            }
                        case "complete":
                            let env = try decoder.decode(CompleteEnvelope.self, from: data)
                            continuation.yield(.complete(env.content))
                        case "error":
                            throw ContentError.badResponse
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct PartialEnvelope: Decodable { let content: PartialPlaceContent }
    private struct CompleteEnvelope: Decodable { let content: PlaceContent }
}
