import Foundation

// Copy this file to `Secrets.swift` and fill in your values.
// `Secrets.swift` is gitignored so your keys never get committed.
enum Secrets {
    // Google Cloud API key, restricted to iOS (your bundle ID) + Places API.
    static let googlePlacesKey = "YOUR_GOOGLE_PLACES_API_KEY"

    // The deployed Cloud Function URL, e.g.
    // https://getplacecontent-xxxxxxxxxx-uc.a.run.app
    // (Firebase prints this after `firebase deploy --only functions`.)
    static let backendURL = "YOUR_GET_PLACE_CONTENT_FUNCTION_URL"
}
