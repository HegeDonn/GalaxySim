import Foundation

/// A version number for people who think in centuries.
///
/// Unix time counts seconds from the start of 1970. This counts from the same
/// instant three hundred years later, so the number is a plain stamp of when
/// this build was switched on — told the way the crew of a ship that flies to
/// other galaxies would tell it. It means nothing to the code. A ship should
/// have a plate on it.
enum Version {
    /// Three hundred Gregorian years. A Gregorian year averages 365.2425
    /// days, which is the whole point of the Gregorian calendar.
    static let offsetSeconds = 300.0 * 365.2425 * 86_400.0

    /// Frozen at first use, so one run reports one number all the way through.
    static let stamp: Int = Int((Date().timeIntervalSince1970 + offsetSeconds).rounded())

    static var date: Date { Date(timeIntervalSince1970: Double(stamp)) }

    /// What goes on the plate: "v11263741108".
    static var short: String { "v\(stamp)" }

    /// The same number said out loud, for anyone who wants to check the maths.
    static var long: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "d MMM yyyy  HH:mm"
        return "\(short)  ·  \(f.string(from: date)) UTC"
    }
}
