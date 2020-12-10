import UIKit
import Starscream

public protocol SocketManagerDelegate: class {
    func socketDidConnect(_ socketManager: SocketManager)
    func socketDidDisconnect(_ socketManager: SocketManager, reason: String, code: UInt16)
    func didReceiveMessage(_ socketManager: SocketManager, message: SocketBaseMessage)
    func didReceiveError(_ error: Error?)
}

public typealias SocketRoute = String
/// In order to handle custom message, please sublclass SocketMessage and use your own data
open class SocketBaseMessage: Codable {
}

open class ATASocketMessage: SocketBaseMessage {
    public let id: Int
    public let method: SocketRoute
    
    public init(id: Int,
         route: SocketRoute) {
        self.id = id
        self.method = route
        super.init()
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case route
    }
    
    required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        //mandatory
        id = try container.decode(Int.self, forKey: .id)
        method = try container.decode(String.self, forKey: .route)
        try super.init(from: decoder)
    }
    
    open override func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(method, forKey: .route)
    }
}

public class SocketManager {
    enum SMError: Error {
        case invalidUrl
    }
    private var socket: WebSocket!
    private var clientIdentifier: UUID!
    private weak var delegate: SocketManagerDelegate!
    private var handledTypes: [SocketBaseMessage.Type] = []
    private(set) var isConnected: Bool = false
    
    public init(root: URL,
         clientIdentifier: UUID,
         delegate: SocketManagerDelegate,
         handledTypes: [SocketBaseMessage.Type]) {
        var request = URLRequest(url: root)
        request.timeoutInterval = 30
        socket = WebSocket(request: request)
        socket.delegate = self
        self.clientIdentifier = clientIdentifier
        self.delegate = delegate
        self.handledTypes = handledTypes
    }
    
    public func connect() {
        socket.connect()
    }
    
    private let decoder: JSONDecoder = JSONDecoder()
    private let encoder: JSONEncoder = JSONEncoder()
    func handle(_ data: Data) {
        handledTypes.forEach { SocketType in
            if let message = try? decoder.decode(SocketType, from: data) {
                delegate?.didReceiveMessage(self, message: message)
            }
        }
    }
    
    public func diconnect() {
        socket.disconnect()
    }
    
    public func send(_ message: SocketBaseMessage, completion: (() -> Void)? = nil) {
        guard let data = try? encoder.encode(message) else { return }
        socket.write(data: data, completion: completion)
    }
}

extension SocketManager: WebSocketDelegate {
    public func didReceive(event: WebSocketEvent, client: WebSocket) {
        switch event {
        case .connected(_):
            isConnected = true
            delegate?.socketDidConnect(self)
            
        case .disconnected(let reason, let code):
            isConnected = false
            delegate?.socketDidDisconnect(self, reason: reason, code: code)
            
        case .text(let text):
            if let data = text.data(using: .utf8) {
                handle(data)
            }
            
        case .binary(let data):
            handle(data)
            
        case .error(let error):
            delegate.didReceiveError(error)
            
        case .reconnectSuggested:
            isConnected = false
            socket.connect()
            
        case .cancelled:
            isConnected = false
            
        case .viabilityChanged: ()
        case .pong: ()
        case .ping: ()
        }
    }
}
