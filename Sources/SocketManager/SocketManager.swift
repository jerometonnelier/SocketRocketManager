import UIKit
import Starscream

public protocol SocketManagerDelegate: class {
    func socketDidConnect(_ socketManager: SocketManager)
    func socketDidDisconnect(_ socketManager: SocketManager, reason: String, code: UInt16)
    func didReceiveMessage(_ socketManager: SocketManager, message: SocketBaseMessage)
    func route(_ route: SocketRoute, failedWith error: ErrorMessage)
    func didReceiveError(_ error: Error?)
}

public typealias SocketRoute = String
/// In order to handle custom message, please sublclass SocketMessage and use your own data
open class SocketBaseMessage: Codable {
}

public struct ErrorMessage: Codable {
    public let errorCode: Int
    public let errorMessage: String
}

open class ATASocketMessage: SocketBaseMessage {
    public let id: Int
    public let method: SocketRoute
    public var error: ErrorMessage?
    // use this to check the decoded method and test again the decoded value
    open var checkMethod: SocketRoute? { nil }
    
    public init(id: Int,
         route: SocketRoute) {
        self.id = id
        self.method = route
        super.init()
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case route = "method"
        case error = "status"
    }
    
    required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        //mandatory
        id = try container.decode(Int.self, forKey: .id)
        method = try container.decode(String.self, forKey: .route)
        error = try container.decodeIfPresent(ErrorMessage.self, forKey: .error)
        try super.init(from: decoder)
        
        // check that the decoded values matches the expected value if provided
        if let route = checkMethod,
           route != method {
            throw SocketManager.SMError.invalidRoute
        }
    }
    
    open override func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(method, forKey: .route)
        try container.encode(error, forKey: .error)
    }
}

public class SocketManager {
    enum SMError: Error {
        case invalidUrl
        case invalidRoute
    }
    private var socket: WebSocket!
    private var clientIdentifier: UUID!
    private weak var delegate: SocketManagerDelegate!
    private var handledTypes: [SocketBaseMessage.Type] = []
    private(set) public var isConnected: Bool = false
    
    public init(root: URL,
         clientIdentifier: UUID,
         delegate: SocketManagerDelegate,
         handledTypes: [SocketBaseMessage.Type]) {
        var request = URLRequest(url: root)
        request.timeoutInterval = 30
        socket = WebSocket(request: request)
        socket.delegate = self
        encoder.outputFormatting = .prettyPrinted
        self.clientIdentifier = clientIdentifier
        self.delegate = delegate
        self.handledTypes = handledTypes
    }
    
    public func connect() {
        socket.connect()
    }
    
    public func diconnect() {
        socket.disconnect()
    }
    
    // send/receive messages
    private let decoder: JSONDecoder = JSONDecoder()
    private let encoder: JSONEncoder = JSONEncoder()
    func handle(_ data: Data) {
        handledTypes.forEach { SocketType in
            if let message = try? decoder.decode(SocketType, from: data) {
                if let ataMessage = message as? ATASocketMessage,
                   let error = ataMessage.error {
                    delegate?.route(ataMessage.method, failedWith: error)
                } else {
                    delegate?.didReceiveMessage(self, message: message)
                }
            }
        }
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
