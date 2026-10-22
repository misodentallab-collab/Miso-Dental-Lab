import UIKit
import WebKit
import CoreLocation

func printView(webView: WKWebView){
    let printController = UIPrintInteractionController.shared

    let printInfo = UIPrintInfo(dictionary:nil)
    printInfo.outputType = UIPrintInfo.OutputType.general
    printInfo.jobName = (webView.url?.absoluteString)!
    printInfo.duplex = UIPrintInfo.Duplex.none
    printInfo.orientation = UIPrintInfo.Orientation.portrait

    printController.printPageRenderer = UIPrintPageRenderer()
          
    printController.printPageRenderer?.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)

    printController.printInfo = printInfo
    printController.showsNumberOfCopies = true
    printController.present(animated: true)
}

// MARK: - MISO 2026-10-22 출근 중 위치 전송 (앱을 닫거나 화면이 꺼져도)
// 웹앱이 출근하면 webkit.messageHandlers['miso-trk'].postMessage({action:'start', tok, url}) 를 보낸다.
// 퇴근하면 {action:'stop'}. 서버가 'notok'(퇴근 처리됨)를 돌려주면 스스로 멈춘다.
// 이동 중에는 5초, 멈춰 있으면 60초마다 위치를 보낸다. 출근 중일 때만 동작한다.

final class MisoTracker: NSObject, CLLocationManagerDelegate {
    static let shared = MisoTracker()
    private let lm = CLLocationManager()
    private var tok: String = ""
    private var endpoint: String = "https://miso-translate.misodentallab.workers.dev/?trk=ping"
    private var lastSent: Date = .distantPast
    private var running = false

    private override init() {
        super.init()
        lm.delegate = self
        lm.desiredAccuracy = kCLLocationAccuracyBest
        lm.distanceFilter = kCLDistanceFilterNone
        lm.activityType = .otherNavigation
        lm.pausesLocationUpdatesAutomatically = false
        let d = UserDefaults.standard
        tok = d.string(forKey: "misoTrkTok") ?? ""
        if let u = d.string(forKey: "misoTrkUrl"), u.hasPrefix("https://") { endpoint = u }
    }

    /// 앱이 다시 켜졌을 때 (출근 중이었다면 이어서 보낸다)
    func resumeIfNeeded() {
        if !tok.isEmpty { begin() }
    }

    func handle(_ body: Any) {
        guard let b = body as? [String: Any] else { return }
        let act = (b["action"] as? String) ?? ""
        if act == "start" {
            let t = (b["tok"] as? String) ?? ""
            if t.isEmpty { return }
            tok = t
            if let u = b["url"] as? String, u.hasPrefix("https://") { endpoint = u }
            save()
            begin()
        } else if act == "stop" {
            stop()
        }
    }

    private func save() {
        UserDefaults.standard.set(tok, forKey: "misoTrkTok")
        UserDefaults.standard.set(endpoint, forKey: "misoTrkUrl")
    }

    private func begin() {
        guard !tok.isEmpty else { return }
        let st = lm.authorizationStatus
        if st == .notDetermined {
            lm.requestWhenInUseAuthorization()
        } else if st == .authorizedWhenInUse {
            lm.requestAlwaysAuthorization()
        }
        if st == .authorizedAlways || st == .authorizedWhenInUse {
            lm.allowsBackgroundLocationUpdates = true
            lm.showsBackgroundLocationIndicator = true
            lm.startUpdatingLocation()
            lm.startMonitoringSignificantLocationChanges()
            running = true
        }
    }

    func stop() {
        tok = ""
        save()
        running = false
        lm.stopUpdatingLocation()
        lm.stopMonitoringSignificantLocationChanges()
        lm.allowsBackgroundLocationUpdates = false
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        guard !tok.isEmpty else { return }
        let st = m.authorizationStatus
        if st == .authorizedWhenInUse {
            m.requestAlwaysAuthorization()
        }
        if (st == .authorizedAlways || st == .authorizedWhenInUse) && !running {
            begin()
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last, !tok.isEmpty else { return }
        let moving = l.speed > 1.0
        let gap: TimeInterval = moving ? 5 : 60
        if Date().timeIntervalSince(lastSent) < gap { return }
        lastSent = Date()
        send(l)
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) { }

    private func send(_ l: CLLocation) {
        guard let url = URL(string: endpoint) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        let body: [String: Any] = [
            "tok": tok,
            "lat": l.coordinate.latitude,
            "lng": l.coordinate.longitude,
            "acc": l.horizontalAccuracy,
            "spd": l.speed,
            "hdg": l.course,
            "src": "ios-bg"
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        var bg: UIBackgroundTaskIdentifier = .invalid
        bg = UIApplication.shared.beginBackgroundTask(withName: "misoTrk") {
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg); bg = .invalid }
        }
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var notok = false
            if let d = data, let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                notok = ((j["error"] as? String) == "notok")
            }
            DispatchQueue.main.async {
                if notok { self.stop() }
                if bg != .invalid { UIApplication.shared.endBackgroundTask(bg); bg = .invalid }
            }
        }.resume()
    }
}
