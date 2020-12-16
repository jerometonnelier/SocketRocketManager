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
        socketManager = SocketManager(root: URL(string: "ws://192.168.1.22:443")!,
                                      clientIdentifier: UUID(),
                                      delegate: self,
                                      handledTypes: [TestSocketMessage.self])
    }

    @IBAction func connect(_ sender: Any) {
        socketManager.connect()
    }
    
    @IBAction func sendMessage(_ sender: Any) {
        socketManager.send(TestSocketMessage(data: ["test" : "My Test"])) {
            
        }
    }
}

class TestSocketMessage: ATASocketMessage {
    var testData: [String: String] = [:]
    
    enum CodingKeys: String, CodingKey {
        case testData = "params"
    }
    
    init(data: [String: String]) {
        super.init(id: 9876, route: "echo")
        self.testData = data
    }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        //mandatory
        testData = try container.decode([String: String].self, forKey: .testData)
        try super.init(from: decoder)
    }
    
    override func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(testData, forKey: .testData)
        try super.encode(to: encoder)
    }

}

extension ViewController: SocketManagerDelegate {
    func socketDidConnect(_ socketManager: SocketManager) {
        socketState.text = "Connecté"
        socketState.textColor = .green
    }
    
    func socketDidDisconnect(_ socketManager: SocketManager, reason: String, code: UInt16) {
        socketState.text = "Déconnecté \(reason)"
        socketState.textColor = .magenta
    }
    
    func didReceiveMessage(_ socketManager: SocketManager, message: SocketBaseMessage) {
        
    }
    
    func didReceiveError(_ error: Error?) {
        socketState.text = "ERROR \(error?.localizedDescription ?? "")"
        socketState.textColor = .red
    }
    
}
