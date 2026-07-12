#if os(iOS)
import Foundation
import Network

/// Discovers Chromecast / Google TV devices on the LAN and casts a Tunarr HLS
/// URL to the built-in default media receiver (app id `CC1AD845`) — no Google
/// Cast SDK. Discovery is Bonjour (`_googlecast._tcp`); the session is a TLS
/// socket speaking CASTV2 (see CastProtocol). All networking state lives on the
/// private `queue`; only the `@Published` UI mirror is written on the main queue.
final class CastController: ObservableObject {
    struct Device: Identifiable, Equatable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
        static func == (a: Device, b: Device) -> Bool { a.id == b.id && a.name == b.name }
    }

    enum Status: Equatable {
        case idle, discovering, connecting(String), casting(String), failed(String)
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var status: Status = .idle
    @Published private(set) var isPaused = false

    var isCasting: Bool { if case .casting = status { return true }; return false }

    private let defaultReceiver = "CC1AD845"
    private let queue = DispatchQueue(label: "com.dbdm.tunarrtv.cast")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var heartbeat: DispatchSourceTimer?
    private var buffer = Data()
    private var requestId = 0
    private var deviceName = ""
    private var mediaTransportId: String?
    private var mediaSessionId: Int?
    private var sessionId: String?
    private var pendingLoad: (url: URL, title: String)?
    private var pausedInternal = false

    deinit {
        browser?.cancel()
        connection?.cancel()
        heartbeat?.cancel()
    }

    // MARK: - Discovery

    func startDiscovery() {
        queue.async {
            guard self.browser == nil else { return }
            let params = NWParameters()
            params.includePeerToPeer = false
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: nil), using: params)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let devices: [Device] = results.map { result in
                    var name = ""
                    if case let .bonjour(txt) = result.metadata,
                       case let .string(friendly) = txt.getEntry(for: "fn") {
                        name = friendly
                    }
                    if name.isEmpty, case let .service(svcName, _, _, _) = result.endpoint {
                        name = svcName
                    }
                    return Device(id: "\(result.endpoint)", name: name.isEmpty ? "Chromecast" : name, endpoint: result.endpoint)
                }
                let sorted = devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                self?.publish { self?.devices = sorted }
            }
            browser.stateUpdateHandler = { [weak self] state in
                if case let .failed(error) = state {
                    self?.publish { self?.status = .failed(error.localizedDescription) }
                }
            }
            self.browser = browser
            browser.start(queue: self.queue)
            self.publish { if self.status == .idle { self.status = .discovering } }
        }
    }

    func stopDiscovery() {
        queue.async {
            self.browser?.cancel()
            self.browser = nil
            self.publish { if self.status == .discovering { self.status = .idle } }
        }
    }

    // MARK: - Casting

    func cast(to device: Device, url: URL, title: String) {
        queue.async {
            self.teardownConnection()
            self.deviceName = device.name
            self.pendingLoad = (url, title)
            self.requestId = 0
            self.publish { self.status = .connecting(device.name); self.isPaused = false }

            let tls = NWProtocolTLS.Options()
            // Chromecasts present a self-signed device certificate; accept it.
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in
                complete(true)
            }, self.queue)
            let params = NWParameters(tls: tls)
            let connection = NWConnection(to: device.endpoint, using: params)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.onConnected()
                case let .failed(error):
                    self.publish { self.status = .failed(error.localizedDescription) }
                    self.queue.async { self.teardownConnection() }
                default:
                    break
                }
            }
            connection.start(queue: self.queue)
            self.receiveLoop(connection)
        }
    }

    /// Pause / resume the receiver without tearing the session down.
    func togglePlayPause() {
        queue.async {
            guard let transport = self.mediaTransportId, let mediaId = self.mediaSessionId else { return }
            let pauseNow = !self.pausedInternal
            self.send(namespace: CastNS.media, destination: transport, payload: [
                "type": pauseNow ? "PAUSE" : "PLAY",
                "mediaSessionId": mediaId,
                "requestId": self.nextRequestId(),
            ])
            self.pausedInternal = pauseNow
            self.publish { self.isPaused = pauseNow }
        }
    }

    func stopCasting() {
        queue.async {
            if let sessionId = self.sessionId {
                self.send(namespace: CastNS.receiver, destination: "receiver-0", payload: [
                    "type": "STOP", "sessionId": sessionId, "requestId": self.nextRequestId(),
                ])
            }
            self.teardownConnection()
            self.publish {
                self.status = self.browser != nil ? .discovering : .idle
                self.isPaused = false
            }
        }
    }

    // MARK: - Session handshake (all on `queue`)

    private func onConnected() {
        // Virtual connection + launch the default media receiver, then heartbeat.
        send(namespace: CastNS.connection, destination: "receiver-0", payload: ["type": "CONNECT"])
        send(namespace: CastNS.receiver, destination: "receiver-0", payload: [
            "type": "LAUNCH", "appId": defaultReceiver, "requestId": nextRequestId(),
        ])
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            self?.send(namespace: CastNS.heartbeat, destination: "receiver-0", payload: ["type": "PING"])
        }
        timer.resume()
        heartbeat = timer
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                for message in CastProto.extractFrames(from: &self.buffer) { self.handle(message) }
            }
            if error == nil && !isComplete, self.connection === connection {
                self.receiveLoop(connection)
            }
        }
    }

    private func handle(_ bytes: [UInt8]) {
        guard let (namespace, payload) = CastProto.parse(bytes),
              let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let type = object["type"] as? String ?? ""
        switch namespace {
        case CastNS.heartbeat:
            if type == "PING" {
                send(namespace: CastNS.heartbeat, destination: "receiver-0", payload: ["type": "PONG"])
            }
        case CastNS.receiver:
            if type == "RECEIVER_STATUS" { handleReceiverStatus(object) }
        case CastNS.media:
            if type == "MEDIA_STATUS" { handleMediaStatus(object) }
        case CastNS.connection:
            if type == "CLOSE" {
                teardownConnection()
                publish { self.status = self.browser != nil ? .discovering : .idle }
            }
        default:
            break
        }
    }

    private func handleReceiverStatus(_ object: [String: Any]) {
        guard let status = object["status"] as? [String: Any],
              let apps = status["applications"] as? [[String: Any]],
              let app = apps.first(where: { ($0["appId"] as? String) == defaultReceiver }),
              let transport = app["transportId"] as? String else { return }
        sessionId = app["sessionId"] as? String
        guard mediaTransportId != transport else { return }
        mediaTransportId = transport
        // Open a virtual connection to the media app, then load the stream.
        send(namespace: CastNS.connection, destination: transport, payload: ["type": "CONNECT"])
        if let load = pendingLoad { sendLoad(url: load.url, title: load.title, transport: transport) }
    }

    private func sendLoad(url: URL, title: String, transport: String) {
        let media: [String: Any] = [
            "contentId": url.absoluteString,
            "streamType": "LIVE",
            "contentType": "application/x-mpegURL",
            "metadata": ["metadataType": 0, "title": title],
        ]
        send(namespace: CastNS.media, destination: transport, payload: [
            "type": "LOAD", "requestId": nextRequestId(), "media": media, "autoplay": true,
        ])
        let name = deviceName
        publish { self.status = .casting(name) }
    }

    private func handleMediaStatus(_ object: [String: Any]) {
        guard let statuses = object["status"] as? [[String: Any]], let status = statuses.first else { return }
        if let mediaId = status["mediaSessionId"] as? Int { mediaSessionId = mediaId }
        let paused = (status["playerState"] as? String) == "PAUSED"
        pausedInternal = paused
        publish { self.isPaused = paused }
    }

    // MARK: - helpers (on `queue`)

    private func send(namespace: String, destination: String, payload: [String: Any]) {
        guard let connection,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let frame = CastProto.frame(namespace: namespace, source: "sender-0", destination: destination, payload: json)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func nextRequestId() -> Int {
        requestId += 1
        return requestId
    }

    private func teardownConnection() {
        heartbeat?.cancel(); heartbeat = nil
        connection?.cancel(); connection = nil
        buffer.removeAll()
        mediaTransportId = nil
        mediaSessionId = nil
        sessionId = nil
        pendingLoad = nil
        pausedInternal = false
    }

    private func publish(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }
}
#endif
