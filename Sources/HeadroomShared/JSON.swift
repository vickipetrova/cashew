import CoreFoundation

/// `JSONSerialization` turns `true`/`false` into `NSNumber`s, and `NSNumber as? Double` happily
/// yields 1.0 and 0.0 — so a boolean sails through any numeric parse unless it is rejected first.
/// Comparing the CoreFoundation type id is the only reliable discriminator: `as? Bool` is no good,
/// because `NSNumber(42) as? Bool` also succeeds. Shared by the usage parser and `Credentials`.
///
/// Lives in `HeadroomShared` because the session files are parsed by both the app and the hook
/// helper, and a second copy of this is exactly the kind of guard that drifts.
public func isJSONBoolean(_ any: Any) -> Bool {
    CFGetTypeID(any as CFTypeRef) == CFBooleanGetTypeID()
}
