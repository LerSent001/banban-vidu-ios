import Foundation
import WebKit
import CryptoKit
import Security

enum DeviceConnection {
    private static let config: [String: String] = {
        guard let url = Bundle.main.url(forResource: "DeviceConfig", withExtension: "json"), let data = try? Data(contentsOf: url), let value = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return value
    }()
    static var baseURL: String {
        #if targetEnvironment(simulator)
        return "http://127.0.0.1:8787"
        #else
        return config["baseURL"] ?? "https://configure-your-vidu-service.invalid"
        #endif
    }
    #if targetEnvironment(simulator)
    static var simulatorCameraToken: String { config["simulatorCameraToken"] ?? "" }
    #endif
    static var host: String { URL(string: baseURL)!.host! }
    static let session = URLSession(configuration: .default, delegate: DeviceTrustDelegate(), delegateQueue: nil)
    static func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        #if !targetEnvironment(simulator)
        request.setValue("Bearer " + (config["token"] ?? ""), forHTTPHeaderField: "Authorization")
        #endif
        return request
    }
    @MainActor static func load(_ webView: WKWebView) async {
        #if !targetEnvironment(simulator)
        if let cookie = HTTPCookie(properties: [.domain: host, .path: "/", .name: "RoomDeviceToken", .value: config["token"] ?? "", .secure: "TRUE", HTTPCookiePropertyKey("HttpOnly"): "TRUE", .expires: Date().addingTimeInterval(7 * 86400)]) {
            await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        }
        #endif
        webView.load(request("/mobile"))
    }
    static func respond(to challenge: URLAuthenticationChallenge, completion: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, challenge.protectionSpace.host == host else { completion(.performDefaultHandling, nil); return }
        // Public hosting uses normal system trust, including hostname and certificate-chain checks.
        if config["trustMode"] == "system" { completion(.performDefaultHandling, nil); return }
        guard let trust = challenge.protectionSpace.serverTrust, let certificate = SecTrustGetCertificateAtIndex(trust, 0), let expected = config["certificateSHA256"] else { completion(.cancelAuthenticationChallenge, nil); return }
        let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
        guard digest == expected else { completion(.cancelAuthenticationChallenge, nil); return }
        // Trust only the exact development service certificate shipped with this build.
        // Keep hostname, expiration and cryptographic validation enabled.
        SecTrustSetAnchorCertificates(trust, [certificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        guard SecTrustEvaluateWithError(trust, nil) else { completion(.cancelAuthenticationChallenge, nil); return }
        completion(.useCredential, URLCredential(trust: trust))
    }
}
private final class DeviceTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        DeviceConnection.respond(to: challenge, completion: completionHandler)
    }
}
