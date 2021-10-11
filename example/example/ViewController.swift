//
//  ViewController.swift
//  example
//
//  Created by GG on 10/12/2020.
//

import UIKit
import SocketManager

class ViewController: UIViewController {

    @IBOutlet weak var socketState: UILabel!
    var socketManager: SocketManager!
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
//        socketManager = SocketManager(root: URL(string: "wss://echo.websocket.org")!,
        socketManager = SocketManager(root: URL(string: "ws://localhost:8080")!,
                                      clientIdentifier: UUID(),
                                      delegate: self,
                                      handledTypes: [LoginResponseMessage.self])
    }

    @IBAction func connect(_ sender: Any) {
        socketManager.connect()
    }
    
    @IBAction func sendMessage(_ sender: Any) {
//        socketManager.send(TestSocketMessage(data: ["test" : "My Test"])) {
//
//        }
    }
}

private struct TokenMessage: Codable {
    let token: String
    let state: Int
}

class LoginMessage: ATAWriteSocketMessage {
    private static let routeToCheck = "Login"
    override var checkMethod: SocketRoute { LoginMessage.routeToCheck }
    
    enum CodingKeys: String, CodingKey {
        case token = "params"
    }
    
    required init(from decoder: Decoder) throws {
        fatalError()
    }
    
    init() {
        super.init(route: LoginMessage.routeToCheck)
    }
    
    init(routeToCheck: SocketRoute) {
        super.init(route: routeToCheck)
    }
    
    override func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(TokenMessage(token: "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE2MzM2ODk5OTYsImlhdCI6MTYzMzY4Mjc5NiwidXNlclV1aWQiOiJmNTY1Yzg5ZS01N2UxLTEwM2ItOTEwZS01OTA4N2Q3ZjkwZmMiLCJ1c2VySWQiOjI5Mn0.Qpm-KY2izkVcq_csz-aXF6TD6jnrWiLcxihYHWgGqJKw2Amk_ANIeFCzsMAjv0_kyIcULSAS9700Smj1yjUVOq79kBNRAQ_ZFO9Z836CLKBs9zTih5nyZs3gYIeMetSkR_uQJkoKJWxpbet8yY1LlO609kqskA7mXoxk9eUZh5ajQebfTkLFHG3uGbhW46ulH8smbr7-jva1Kb7LQlhmOMCr8-vZrV1Alws_CGAi_8OxqA_kS9VLkTOsrHM4BuVkqPNymVit1fBTHGZs1n9dS_XJeSA5Pg8emrrHnab10FuqEvSDpUFhyRsubZbqZg7-OE38poCaDyC8sf4UmtBslA", state: 0), forKey: .token)
        try super.encode(to: encoder)
    }
}

class LoginResponseMessage: ATAReadSocketMessage<LoginMessage> {
    static let routeToCheck = "LoginResponse"
    override var checkMethod: SocketRoute { LoginResponseMessage.routeToCheck }
    
    enum CodingKeys: String, CodingKey {
        case token = "params"
    }
    
    required init(from decoder: Decoder) throws {
        do {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            //mandatory
            guard try container.decodeIfPresent(TokenMessage.self, forKey: .token) != nil else {
                throw EncodingError.invalidValue("Token", EncodingError.Context.init(codingPath: [CodingKeys.token], debugDescription: "Token is missing"))
            }
            try super.init(from: decoder)
        } catch (let error) {
            throw error
        }
    }
}

extension ViewController: SocketManagerDelegate {
    func route(_ route: SocketRoute, failedWith error: SocketErrorMessage, message: ATAErrorSocketMessage) {
        print("\(route) failedWith \(error) from \(message)")
    }
    
    func socketDidConnect(_ socketManager: SocketManager) {
        socketState.text = "Connecté"
        socketState.textColor = .green
        socketManager.send(LoginMessage())
    }
    
    func socketDidDisconnect(_ socketManager: SocketManager, reason: String, code: UInt16) {
        socketState.text = "Déconnecté \(reason)"
        socketState.textColor = .magenta
    }
    
    func didReceiveMessage(_ socketManager: SocketManager, message: SocketBaseMessage) {
        print(message)
    }
    
    func didReceiveError(_ error: Error?) {
        socketState.text = "ERROR \(error?.localizedDescription ?? "")"
        socketState.textColor = .red
    }
    
}
