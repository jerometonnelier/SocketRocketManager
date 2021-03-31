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
                if isConnected == false, state != .connecting {
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
    public var isConnected: Bool { state == .connected }
    // the timeout duration for message sending after which the socket will try to send a new message
    public var timeout: Double = 10.0
    private var timeOutData: [ATAWriteSocketMessage: (date: Date, retries: Int)] = [:]
    public var isVerbose: Bool = false
    // the date at which the last package was went in order to delay at meast 10ms the sending of messages
    private var lastSentPackage: Date = Date()
    enum ConnectionState {
        case disconnected, connecting, connected
    }
    private(set) var state: ConnectionState = .disconnected
    
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
        state = .connecting
        socket.connect()
    }
    
    public func diconnect() {
        socket.disconnect()
    }
    
    // send/receive messages
    private let decoder: JSONDecoder = JSONDecoder()
    private let encoder: JSONEncoder = JSONEncoder()
    func handle(_ data: Data) {
        log("Received Data \(String(data: data, encoding: .utf8) ?? "")")
        handledTypes.forEach { SocketType in
            if let message = try? decoder.decode(SocketType, from: data) {
                removeObserver(for: message)
                if let ataMessage = message as? ATAReadSocketMessage,
                   ataMessage.error.errorCode != 0 {
                    delegate?.route(ataMessage.method, failedWith: ataMessage.error, message: ataMessage)
                } else {
                    delegate?.didReceiveMessage(self, message: message)
                }
            }
        }
    }
    
    // concurrence queues https://medium.com/cubo-ai/concurrency-thread-safety-in-swift-5281535f7d3a
    private let messageQueue = DispatchQueue(label: "sendQueue", attributes: .concurrent)
    public func send(_ message: SocketBaseMessage, completion: (() -> Void)? = nil) {
        guard let data = try? encoder.encode(message) else { return }
        log("Send \(String(data: data, encoding: .utf8) ?? "")")
        // add a minimul delay of 10ms between each messages
        let interval = Date().timeIntervalSince(lastSentPackage) / 100.0
        let delay = interval <= 0.01 ? 0.01 : 0
        lastSentPackage = Date().addingTimeInterval(0.001)
        messageQueue.asyncAfter(deadline: .now() + delay, flags: .barrier) { [weak self] in
            self?.socket.write(data: data, completion: completion)
        }
        
        if let writeMsg = message as? ATAWriteSocketMessage, writeMsg.awaitsAnswer {
            log("Observe response for \(message.id)")
            timeOutData[writeMsg] = (date: Date(), retries: 0)
            handleTimeout(for: writeMsg)
        }
    }
    
    private func handleTimeout(for message: ATAWriteSocketMessage) {
        log("Handle timeout for \(message.id)")
        // if the message received an answer, donc't handle
        guard let data = timeOutData[message] else {
            log("🍀 response already received for \(message.id)")
            return
        }
        // if the message was already sent more than 1 time, thorw an error
        guard data.retries < 1 else {
            log("🔥 no response received for \(message.id), triggering an error")
            delegate?.route(message.method, failedWith: SocketErrorMessage.retryFailed, message: ATAReadSocketMessage(id: message.id, route: message.method))
            return
        }
        // otherwise, dispatch a second attempt after timeout``
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.retryToSend(message)
        }
    }
    
    private func retryToSend(_ message: ATAWriteSocketMessage) {
        log("retry To Send for \(message.id)")
        guard var data = timeOutData[message] else {
            log("🍀 response already received for \(message.id)")
            return
        }
        data.retries += 1
        timeOutData[message] = data
        handleTimeout(for: message)
        send(message)
    }
    
    private func removeObserver(for message: SocketBaseMessage) {
        log("Remove oObserver for \(message.id)")
        if let index = timeOutData.firstIndex(where: { $0.key.id == message.id }) {
            log("🍀 removed")
            timeOutData.remove(at: index)
        } else {
            log("🔥 no data found to remove")
        }
    }
    
    func log(_ message: String) {
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
            state = .connected
            delegate?.socketDidConnect(self)
            
        case .disconnected(let reason, let code):
            log("Disonnected \(reason)")
            state = .disconnected
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
            state = .disconnected
            connect()
            
        case .cancelled:
            log("cancelled")
            state = .disconnected
            // try to reconnect
            messageQueue.asyncAfter(deadline: .now() + 5, flags: .barrier) { [weak self] in
                self?.connect()
            }
            
        case .viabilityChanged(let success):
            log("viabilityChanged \(success)")
            if success == true, state == .disconnected {
                state = .connecting
                connect()
            }
            if state != .connecting {
                state = success ? .connected : .disconnected
            }
            
        case .pong: log("pong")
        case .ping: log("ping")
        }
    }
}
