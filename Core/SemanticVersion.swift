import Foundation

/// Numeric semantic version comparison. Handles "1.0.10" > "1.0.9" correctly.
/// Missing components are treated as 0, so "1.1" == "1.1.0".
enum SemanticVersion {

    /// Returns true if `lhs` represents a strictly newer version than `rhs`.
    static func compare(_ lhs: String, isGreaterThan rhs: String) -> Bool {
        let lhsParts = lhs.split(separator: ".").map(String.init)
        let rhsParts = rhs.split(separator: ".").map(String.init)
        let count = max(lhsParts.count, rhsParts.count)

        for i in 0..<count {
            let left  = i < lhsParts.count ? lhsParts[i] : "0"
            let right = i < rhsParts.count ? rhsParts[i] : "0"

            if let l = Int(left), let r = Int(right) {
                if l != r { return l > r }
            } else {
                if left != right { return left > right }
            }
        }
        return false // equal
    }
}
