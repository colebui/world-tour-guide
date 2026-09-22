import Foundation
import MapKit

/// Travel mode for directions. Walk/drive route via Apple MKDirections (free, in-app);
/// transit routes via the Google Directions API (drawn in-app on the same Apple map).
enum TransportMode: String, CaseIterable, Identifiable {
    case walk, drive, transit

    var id: String { rawValue }

    var label: String {
        switch self {
        case .walk: return "Walk"
        case .drive: return "Drive"
        case .transit: return "Transit"
        }
    }

    var symbol: String {
        switch self {
        case .walk: return "figure.walk"
        case .drive: return "car.fill"
        case .transit: return "tram.fill"
        }
    }

    /// Apple route types compute walk/drive in-app; transit goes through Google instead.
    var usesApple: Bool { self != .transit }

    var mkType: MKDirectionsTransportType {
        switch self {
        case .walk: return .walking
        case .drive: return .automobile
        case .transit: return .transit
        }
    }

    /// Apple Maps launch directions mode (for the Navigate handoff).
    var launchMode: String {
        switch self {
        case .walk: return MKLaunchOptionsDirectionsModeWalking
        case .drive: return MKLaunchOptionsDirectionsModeDriving
        case .transit: return MKLaunchOptionsDirectionsModeTransit
        }
    }
}
