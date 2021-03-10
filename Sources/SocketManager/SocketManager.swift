import UIKit
import Starscream
import Network

// MARK: - Protocols
public protocol SocketManagerDelegate: class {
    func socketDidConnect(_ socketManager: SocketManager)
    func socketDidDisconnect(_ socketManager: SocketManager, reason: String, code: UInt16)
    func didReceiveMessage(_ socketManager: SocketManager, message: SocketBaseMessage)
    func route(_ route: SocketRoute, failedWith error: SocketErrorMessage, message: ATAReadSocketMessage)
    func didReceiveError(_ error: Error?)
}

public typealias SocketRoute = String
/// In order to handle custom message, please sublclass SocketMessage and use your own data
open class SocketBaseMessage: Codable {
}

public struct SocketErrorMessage: Codable {
    public let errorCode: Int
    public let errorMessage: String
}

// MARK: - Messages
open class ATAReadSocketMessage: ATAWriteSocketMessage {
    public var error: SocketErrorMessage
    public let id: Int
    
    public override init(id: Int,
         route: SocketRoute) {
        self.error = SocketErrorMessage(errorCode: 0, errorMessage: "")
        self.id = id
        super.init(id: id, route: route)
    }
    
    enum CodingKeys: String, CodingKey {
        case status
        case id
    }
    
    required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        error = try container.decode(SocketErrorMessage.self, forKey: .status)
        try super.init(from: decoder)
    }
}

open class ATAWriteSocketMessage: SocketBaseMessage {
    public let method: SocketRoute
    // use this to check the decoded method and test again the decoded value
    open var checkMethod: SocketRoute? { nil }
    
    public init(id: Int,
         route: SocketRoute) {
        self.method = route
        super.init()
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case route = "method"
    }
    
    required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        //mandatory
        method = try container.decode(String.self, forKey: .route)
        try super.init(from: decoder)
        
        // check that the decoded values matches the expected value if provided
        if let route = checkMethod,
           route != method {
            throw SocketManager.SMError.invalidRoute
        }
    }
    
    open override func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(method, forKey: .route)
    }
}

// MARK: - SocketManager
public class SocketManager {
    enum SMError: Error {
        case invalidUrl
        case invalidRoute
    }
    private (set) var networkPath: NWPath?  {
        didSet {
            guard let path = networkPath else { return }
            switch path.status {
            case .satisfied:
                if isConnected == false {
                    DispatchQueue.main.async { [weak self] in
                        self?.reconnect()
                    }
                }
                
            default: ()
            }
        }
    }
    private let queue = DispatchQueue(label: "SocketMonitor")
    private let monitor = NWPathMonitor()
    private var socket: WebSocket!
    private var clientIdentifier: UUID!
    private weak var delegate: SocketManagerDelegate!
    private var handledTypes: [SocketBaseMessage.Type] = []
    private(set) public var isConnected: Bool = false
    public var isVerbose: Bool = false
    
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
        
        monitor.pathUpdateHandler = { [weak self] path in
            self?.networkPath = path
        }
        monitor.start(queue: queue)
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
        log(String(data: data, encoding: .utf8))
        handledTypes.forEach { SocketType in
            if let message = try? decoder.decode(SocketType, from: data) {
                if let ataMessage = message as? ATAReadSocketMessage,
                   ataMessage.error.errorCode != 0 {
                    delegate?.route(ataMessage.method, failedWith: ataMessage.error, message: ataMessage)
                } else {
                    delegate?.didReceiveMessage(self, message: message)
                }
            }
        }
    }
    
    public func send(_ message: SocketBaseMessage, completion: (() -> Void)? = nil) {
        guard let data = try? encoder.encode(message) else { return }
        log("Send \(String(data: data, encoding: .utf8) ?? "")")
        socket.write(data: data, completion: completion)
    }
    
    func log(_ message: String?) {
        guard isVerbose == true else { return }
        print("🧦 \(String(describing: message))")
    }
    
    func reconnect(after seconds: Double = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.connect()
        }
    }
}

extension SocketManager: WebSocketDelegate {
    public func didReceive(event: WebSocketEvent, client: WebSocket) {
        switch event {
        case .connected(_):
            log("Connected")
            isConnected = true
            delegate?.socketDidConnect(self)
            
        case .disconnected(let reason, let code):
            log("Disonnected \(reason)")
            isConnected = false
            delegate?.socketDidDisconnect(self, reason: reason, code: code)
            
        case .text(let text):
            log("Received - \(text)")
            if let data = text.data(using: .utf8) {
                handle(data)
            }
            
        case .binary(let data):
            handle(data)
            
        case .error(let error):
            log("Error - \(String(describing: error))")
            delegate.didReceiveError(error)
            if let wsError = error as? Starscream.WSError {
                switch (wsError.type, wsError.code) {
                case (.securityError, 1): reconnect(after: 5)
                default: ()
                }
            }
            
            if let httpError = error as? Starscream.HTTPUpgradeError {
                switch httpError {
                case .notAnUpgrade(200): reconnect(after: 5)
                default: ()
                }
            }
            
        case .reconnectSuggested:
            log("reconnectSuggested")
            isConnected = false
            connect()
            
        case .cancelled:
            log("cancelled")
            isConnected = false
            
        case .viabilityChanged(let success):
            log("viabilityChanged \(success)")
            if success == true, isConnected == false {
                connect()
            }
            isConnected = success
            
        case .pong: log("pong")
        case .ping: log("ping")
        }
    }
}
