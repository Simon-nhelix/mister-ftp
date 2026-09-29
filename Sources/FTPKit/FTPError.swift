import Foundation
import Darwin

public enum FTPError: Error, Equatable, LocalizedError {
    case hostNotFound(String)
    case connectFailed(host: String, code: Int32)
    case timeout
    case connectionClosed
    case loginFailed(String)
    /// The server answered with an error code (4xx or 5xx) or a code we did not expect.
    case server(code: Int, message: String)
    case protocolError(String)
    case invalidName(String)
    case localFile(String)
    case cancelled

    /// The control connection is gone. A new connection may work.
    public var isConnectionLost: Bool {
        switch self {
        case .connectionClosed, .timeout: return true
        case .server(let code, _): return code == 421
        default: return false
        }
    }

    /// True when the operating system blocked the connection before it left the Mac.
    /// On macOS 15 and later this is how a missing "Local Network" permission looks.
    public var looksLikeLocalNetworkBlock: Bool {
        if case .connectFailed(_, let code) = self { return code == EHOSTUNREACH || code == ENETUNREACH || code == EPERM }
        return false
    }

    /// FTPKit has no strings of its own: String(localized:) looks in the main bundle,
    /// so the app's Localizable string catalog translates these.
    public var errorDescription: String? {
        switch self {
        case .hostNotFound(let host):
            return String(localized: "\(host) 주소를 찾지 못했어요.")
        case .connectFailed(let host, let code):
            switch code {
            case ECONNREFUSED: return String(localized: "\(host)에서 FTP 서버가 켜져 있지 않아요.")
            case EHOSTUNREACH, ENETUNREACH, EPERM: return String(localized: "\(host)에 연결할 수 없어요. 네트워크나 로컬 네트워크 권한을 확인하세요.")
            default: return String(localized: "\(host)에 연결하지 못했어요. (\(String(cString: strerror(code))))")
            }
        case .timeout:
            return String(localized: "MiSTer가 응답하지 않아요. 네트워크 연결을 확인하세요.")
        case .connectionClosed:
            return String(localized: "MiSTer와 연결이 끊어졌어요.")
        case .loginFailed:
            return String(localized: "로그인하지 못했어요. 사용자 이름과 비밀번호를 확인하세요.")
        case .server(let code, let message):
            switch code {
            case 550: return String(localized: "권한이 없거나 이미 없는 항목이에요. (\(message))")
            case 552: return String(localized: "MiSTer의 저장 공간이 부족해요.")
            case 553: return String(localized: "이 이름은 쓸 수 없어요. (\(message))")
            default: return String(localized: "MiSTer가 요청을 거절했어요: \(code) \(message)")
            }
        case .protocolError(let line):
            return String(localized: "FTP 서버의 응답을 이해하지 못했어요: \(line)")
        case .invalidName(let name):
            return String(localized: "‘\(name)’은(는) 쓸 수 없는 이름이에요.")
        case .localFile(let message):
            return message
        case .cancelled:
            return String(localized: "취소했어요.")
        }
    }
}
