import UIKit
import SocketRocket
import Combine

// MARK: - Protocols
public protocol SocketManagerDelegate: NSObjectProtocol {
    func socketDidConnect(_ socketManager: SocketManager)
    func socketDidDisconnect(_ socketManager: SocketManager, reason: String, code: UInt16)
    func didReceiveMessage(_ socketManager: SocketManager, message: SocketBaseMessage)
    func route(_ route: SocketRoute, failedWith error: SocketErrorMessage, message: ATAErrorSocketMessage)
    func didReceiveError(_ error: Error?)
}

public struct RouteFailure {
    public let route: SocketRoute
    public let error: SocketErrorMessage
    public let message: ATAErrorSocketMessage
}

public enum WebSocketEvent {
    case connected
    case disconnected(String?, Int)
    case text(String)
    case binary(Data)
    case pong(Data?)
    case ping(Data?)
    case error(Error?)
    case viabilityChanged(Bool)
    case reconnectSuggested(Bool)
    case cancelled
}

// MARK: - SocketManager
public class SocketManager: NSObject, ObservableObject {
    enum SMError: Error {
        case invalidUrl
        case invalidRoute
    }
    private var socket: SRWebSocket!
    private var clientIdentifier: UUID!
    private weak var delegate: SocketManagerDelegate!
    private var handledTypes: [SocketBaseMessage.Type] = []
    // the timeout duration for message sending after which the socket will try to send a new message
    public var timeout: Double = 10.0
    private var timeOutData: [ATAWriteSocketMessage: (date: Date, retries: Int)] = [:]
    public var isVerbose: Bool = false
    // the date at which the last package was went in order to delay at meast 10ms the sending of messages
    private var lastSentPackage: Date = Date()
    public enum ConnectionState {
        case disconnecting, disconnected, connecting, connected
    }
    
    public func clearTimeOutData() {
        timeOutData.removeAll()
    }
    public func clearTimeOutData(forRoute route: SocketRoute) {
        guard let message = timeOutData.keys.filter({ $0.checkMethod == route }).first else { return }
        timeOutData[message] = nil
    }
    
    @Published private(set) var state: ConnectionState = .disconnected
    @Published public var isConnected: Bool = false
    // combine values
    private var subscriptions = Set<AnyCancellable>()
    private var pingSubscriptions = Set<AnyCancellable>()
    public var useCombine: Bool = false  {
        didSet {
            if useCombine && subscriptions.isEmpty {
                loadObservers()
            } else if !useCombine && !subscriptions.isEmpty {
                subscriptions.removeAll()
            }
        }
    }
    // errors
    public var errorPublisher: AnyPublisher<Error?, Error> {
        errorSubject.eraseToAnyPublisher()
    }
    private var errorSubject: PassthroughSubject<Error?, Error> = PassthroughSubject<Error?, Error>()
    // messages
    public var messagesPublisher: AnyPublisher<SocketBaseMessage, Error> {
        messagesSubject.eraseToAnyPublisher()
    }
    private var messagesSubject: PassthroughSubject<SocketBaseMessage, Error> = PassthroughSubject<SocketBaseMessage, Error>()
    // route fail
    public var routeFailedPublisher: AnyPublisher<RouteFailure, Error> {
        routeFailedSubject.eraseToAnyPublisher()
    }
    private var routeFailedSubject: PassthroughSubject<RouteFailure, Error> = PassthroughSubject<RouteFailure, Error>()
    private var eventPublisher: PassthroughSubject<WebSocketEvent, Error> = PassthroughSubject<WebSocketEvent, Error>()
    
    // conf
    public var handleBackgroundMode: Bool = true
    public var backgroundModeHandler: (() -> Void)?
    public var handleConnectedStateAutomatically: Bool = true
    public var timerDuration: Double!  {
        didSet {
            startPings()
        }
    }

    public init(root: URL,
                requestCompletion: ((inout URLRequest) -> Void)? = nil,
                clientIdentifier: UUID,
                delegate: SocketManagerDelegate,
                handledTypes: [SocketBaseMessage.Type]) {
        super.init()
        var request = URLRequest(url: root)
        request.timeoutInterval = 30
        requestCompletion?(&request)
        socket = SRWebSocket(url: root, protocols: request.allHTTPHeaderFields?.values.compactMap({ $0 }))
        socket.delegate = self
        encoder.outputFormatting = .prettyPrinted
        self.clientIdentifier = clientIdentifier
        self.delegate = delegate
        self.handledTypes = handledTypes
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if timerDuration == nil {
            timerDuration = 30
        }
        handleLifeCycle()
        loadObservers()
        // set the isConected published value
        $state
            .sink { [weak self] state in
                self?.log("Change state to \(state) 🔋")
                self?.isConnected = state == .connected
            }
            .store(in: &subscriptions)
    }
    
    private(set) public var appIsInForeground: Bool = true
    private func handleLifeCycle() {
        startPings()
        
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self = self else { return }
            if self.handleBackgroundMode {
                self.appIsInForeground = false
                self.disconnect()
                self.pingSubscriptions.removeAll()
            } else {
                self.backgroundModeHandler?()
            }
        }
        
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.appIsInForeground = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.connect()
                self?.startPings()
            }
        }
    }
    
    public func socketDidlMoveToBackground() {
        appIsInForeground = false
        disconnect()
        pingSubscriptions.removeAll()
    }
    
    private func startPings() {
        pingSubscriptions.removeAll()
        Timer
            .publish(every: timerDuration, on: .main, in: .default)
            .autoconnect()
            .sink { [weak self] _ in
                self?.ping()
            }
            .store(in: &pingSubscriptions)
    }
    
    // Combine stuff
    private func loadObservers() {
    }
    
    public func publisher<T: SocketBaseMessage>() -> AnyPublisher<T, Error> {
        eventPublisher
            .compactMap { [weak self] event -> Data? in
                switch event {
                case .binary(let data): return data
                case .text(let text):
                    self?.log("Received - \(text)")
                    if let data = text.data(using: .utf8) {
                        return data
                    }
                    
                default: ()
                }
                return nil
            }
            .decode(type: T.self, decoder: JSONDecoder())
            .eraseToAnyPublisher()
    }
    
    public func connect() {
        log("CONNECT(🔌)")
        guard appIsInForeground, [.connecting, .connected].contains(state) == false else { return }
        log("SEND CONNEXION MESSAGE 📧")
        state = .connecting
        socket.open()
    }
    
    public func disconnect() {
        log("DISCONNECTING")
        state = .disconnecting
        socket.close()
    }
    
    public func update(to state: ConnectionState) {
        self.state = state
    }
    
    // send/receive messages
    private let decoder: JSONDecoder = JSONDecoder()
    private let encoder: JSONEncoder = JSONEncoder()
    func handle(_ data: Data) {
        log("Received Data \(String(data: data, encoding: .utf8) ?? "")")
        handledTypes.forEach { SocketType in
            if let message = try? decoder.decode(SocketType, from: data) {
                removeObserver(for: message)
                if let ataMessage = message as? ATAErrorSocketMessage,
                   ataMessage.error.errorCode != 0 {
                    delegate?.route(ataMessage.method, failedWith: ataMessage.error, message: ataMessage)
                    if useCombine {
                        routeFailedSubject.send(RouteFailure(route: ataMessage.method, error: ataMessage.error, message: ataMessage))
                    }
                } else {
                    delegate?.didReceiveMessage(self, message: message)
                    if useCombine {
                        messagesSubject.send(message)
                    }
                }
            }
        }
    }
    
    // concurrence queues https://medium.com/cubo-ai/concurrency-thread-safety-in-swift-5281535f7d3a
    private let messageQueue = DispatchQueue(label: "sendQueue", attributes: .concurrent)
    private let minimumSendDelay: TimeInterval = 0.01
    public func send(_ message: SocketBaseMessage) {
        guard let data = try? encoder.encode(message) else { return }
        log("Send \(String(data: data, encoding: .utf8) ?? "")")
        // add a minimul delay of 10ms between each messages
        let interval = Date().timeIntervalSince(lastSentPackage) / 100.0
        let delay = interval <= minimumSendDelay ? minimumSendDelay : 0
        lastSentPackage = Date().addingTimeInterval(minimumSendDelay)
        messageQueue.asyncAfter(deadline: .now() + delay, flags: .barrier) { [weak self] in
            try? self?.socket.send(data: data)
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
            delegate?.route(message.method, failedWith: SocketErrorMessage.retryFailed, message: ATAErrorSocketMessage(id: message.id, route: message.method))
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
    
    public var logEmote: String = "🧦"
    func log(_ message: String) {
        guard isVerbose == true else { return }
        print("\(logEmote) \(String(describing: message))")
    }
    
    func reconnect(after seconds: Double = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.connect()
        }
    }
    
    public func ping() {
        guard isConnected else { return }
        log("send ping 🏓")
        try? socket.sendPing("".data(using: .utf8)!)
    }
    
    // MARK: - Combine
//    private let
}

extension SocketManager: SRWebSocketDelegate {
    public func webSocketDidOpen(_ webSocket: SRWebSocket) {
        eventPublisher.send(.connected)
        log("Connected")
        if handleConnectedStateAutomatically {
            state = .connected
        }
        delegate?.socketDidConnect(self)
    }
    
    public func webSocket(_ webSocket: SRWebSocket, didReceiveMessage message: Any) {
        switch message {
        case is Data:
            let data = message as! Data
            eventPublisher.send(.binary(data))
            handle(data)
        case is String:
            guard let data = (message as? String)?.data(using: .utf8) else { return }
            eventPublisher.send(.binary(data))
            handle(data)
        default: ()
        }
    }
    
    public func webSocket(_ webSocket: SRWebSocket, didReceivePong pongData: Data?) {
        eventPublisher.send(.pong(pongData))
        log("pong")
    }
    
    public func webSocket(_ webSocket: SRWebSocket, didReceiveMessageWith string: String) {
        eventPublisher.send(.text(string))
    }
    
    public func webSocket(_ webSocket: SRWebSocket, didFailWithError error: Error) {
        eventPublisher.send(.error(error))
        log("Error - \(String(describing: error))")
        delegate.didReceiveError(error)
        if useCombine {
            errorSubject.send(error)
        }
//        if let wsError = error as? Starscream.WSError {
//            switch (wsError.type, wsError.code) {
//            case (.securityError, 1): reconnect(after: 5)
//            default: ()
//            }
//        }
//        
//        if let httpError = error as? Starscream.HTTPUpgradeError {
//            switch httpError {
//            case .notAnUpgrade(200, _): reconnect(after: 5)
//            default: ()
//            }
//        }
    }
    
    public func webSocket(_ webSocket: SRWebSocket, didCloseWithCode code: Int, reason: String?, wasClean: Bool) {
        eventPublisher.send(.disconnected(reason, code))
        log("Disonnected \(reason ?? "")")
        state = .disconnected
        delegate?.socketDidDisconnect(self, reason: reason ?? "", code: UInt16(code))
    }
    
    public func webSocket(_ webSocket: SRWebSocket, didReceivePingWith data: Data?) {
        eventPublisher.send(.ping(data))
        log("ping")
    }
    
    public func webSocket(_ webSocket: SRWebSocket, didReceiveMessageWith data: Data) {
        eventPublisher.send(.binary(data))
        handle(data)
    }
    
    public func webSocketShouldConvertTextFrameToString(_ webSocket: SRWebSocket) -> Bool {
        true
    }
}
//
//extension SocketManager: WebSocketDelegate {
//    public func didReceive(event: WebSocketEvent, client: WebSocketClient) {
//        eventPublisher.send(event)
//
//        switch event {
//        case .connected(_):
//            log("Connected")
//            if handleConnectedStateAutomatically {
//                state = .connected
//            }
//            delegate?.socketDidConnect(self)
//
//        case .disconnected(let reason, let code):
//
//        case .text(let text):
//            log("Received - \(text)")
//            if let data = text.data(using: .utf8) {
//                handle(data)
//            }
//
//        case .binary(let data):
//            handle(data)
//
//        case .error(let error):
//            log("Error - \(String(describing: error))")
//            delegate.didReceiveError(error)
//            if useCombine {
//                errorSubject.send(error)
//            }
//            if let wsError = error as? Starscream.WSError {
//                switch (wsError.type, wsError.code) {
//                case (.securityError, 1): reconnect(after: 5)
//                default: ()
//                }
//            }
//
//            if let httpError = error as? Starscream.HTTPUpgradeError {
//                switch httpError {
//                case .notAnUpgrade(200, _): reconnect(after: 5)
//                default: ()
//                }
//            }
//
//        case .reconnectSuggested:
//            log("reconnectSuggested")
//            state = .disconnected
//            connect()
//
//        case .cancelled:
//            log("cancelled")
//            if state != .disconnecting {
//                // try to reconnect
//                messageQueue.asyncAfter(deadline: .now() + 5, flags: .barrier) { [weak self] in
//                    self?.connect()
//                }
//            }
//            state = .disconnected
//
//        case .viabilityChanged(let success):
//            log("viabilityChanged \(success)")
//            if success == true, state == .disconnected {
//                state = .connecting
//                connect()
//            }
//            if state != .connecting {
//                state = success ? .connected : .disconnected
//            }
//
//        case .pong: log("pong")
//        case .ping: log("ping")
//        }
//    }
//}
