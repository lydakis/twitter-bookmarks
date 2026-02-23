import Foundation

public protocol ExpressibleByArgument {
    init?(argument: String)
}

public extension ExpressibleByArgument where Self: RawRepresentable, Self.RawValue == String {
    init?(argument: String) {
        self.init(rawValue: argument)
    }
}

public struct ValidationError: Error, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}
