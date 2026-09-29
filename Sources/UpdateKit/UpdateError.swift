import Foundation

/// UpdateKit has no strings of its own: String(localized:) looks in the main
/// bundle, so the app's Localizable string catalog translates these.
public enum UpdateError: Error, Equatable, LocalizedError {
    case offline
    case rateLimited
    case server(Int)
    case badResponse
    case unsigned
    case insecureURL
    case download(String)
    case badSignature
    case noAppInArchive
    case wrongApp
    case notNewer
    case codeSignature
    case translocated
    case notWritable(String)
    case install(String)

    public var errorDescription: String? {
        switch self {
        case .offline:
            return String(localized: "인터넷에 연결되어 있지 않아요.")
        case .rateLimited:
            return String(localized: "GitHub이 잠시 요청을 막았어요. 조금 뒤에 다시 확인하세요.")
        case .server(let code):
            return String(localized: "GitHub이 요청에 답하지 않았어요. (HTTP \(code))")
        case .badResponse:
            return String(localized: "GitHub의 릴리스 정보를 읽지 못했어요.")
        case .unsigned:
            return String(localized: "이 버전에는 서명 파일이 없어 앱에서 바로 설치할 수 없어요. 릴리스 페이지에서 받아 주세요.")
        case .insecureURL:
            return String(localized: "안전하지 않은 주소라서 받지 않았어요.")
        case .download(let reason):
            return String(localized: "새 버전을 받지 못했어요. (\(reason))")
        case .badSignature:
            return String(localized: "받은 파일의 서명이 맞지 않아 설치하지 않았어요.")
        case .noAppInArchive:
            return String(localized: "받은 파일 안에 앱이 없어요.")
        case .wrongApp:
            return String(localized: "받은 앱이 MiSTer FTP의 새 버전이 아니라서 설치하지 않았어요.")
        case .notNewer:
            return String(localized: "받은 앱이 지금 버전보다 새것이 아니에요.")
        case .codeSignature:
            return String(localized: "받은 앱이 손상되어 설치하지 않았어요.")
        case .translocated:
            return String(localized: "앱을 응용 프로그램 폴더로 옮긴 다음 다시 업데이트하세요.")
        case .notWritable(let folder):
            return String(localized: "‘\(folder)’ 폴더를 바꿀 권한이 없어 업데이트하지 못했어요.")
        case .install(let reason):
            return String(localized: "새 버전을 설치하지 못했어요. (\(reason))")
        }
    }
}
