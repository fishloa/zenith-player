import Foundation

public protocol Transport: AnyObject {
    func start(conn: UInt32, method: String, url: URL, headers: [(String, String)], range: ClosedRange<UInt64>?)
    func connect(conn: UInt32, host: String, port: UInt16, tls: Bool)
    func send(conn: UInt32, bytes: Data)
    func cancel(conn: UInt32)
    func invalidate()
}

public typealias TransportFactory = (DispatchQueue,
                              @escaping (UInt32, Int, [(String, String)]) -> Void,
                              @escaping (UInt32, Data) -> Void,
                              @escaping (UInt32, String?) -> Void,
                              @escaping (UInt32) -> Void) -> Transport
