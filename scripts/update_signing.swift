// Signs release archives for the in-app updater (Ed25519).
//
//   swift scripts/update_signing.swift generate     make the key once; puts the public key in Resources/Info.plist
//   swift scripts/update_signing.swift sign <file>  writes <file>.sig and checks it against Info.plist
//   swift scripts/update_signing.swift check        confirms the keychain key matches Info.plist
//
// The private key lives only in the login keychain (item "MiSTer FTP update signing key").
// Back it up: without it, installed copies can no longer update themselves.
import CryptoKit
import Foundation

let service = "MiSTer FTP update signing key"
let account = "io.github.simon-nhelix.misterftp"
let infoPlist = "Resources/Info.plist"
let plistKey = "MFTPUpdatePublicKey"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

@discardableResult
func run(_ tool: String, _ arguments: [String], quiet: Bool = false) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = quiet ? FileHandle.nullDevice : FileHandle.standardError
    do { try process.run() } catch { fail("could not run \(tool)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

/// The private key from the keychain, never printed.
func privateKey() -> Curve25519.Signing.PrivateKey? {
    let result = run("/usr/bin/security", ["find-generic-password", "-s", service, "-a", account, "-w"], quiet: true)
    guard result.status == 0, let raw = Data(base64Encoded: result.output) else { return nil }
    return try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
}

func plistPublicKey() -> String? {
    let result = run("/usr/libexec/PlistBuddy", ["-c", "Print :\(plistKey)", infoPlist], quiet: true)
    return result.status == 0 && !result.output.isEmpty ? result.output : nil
}

func setPlistPublicKey(_ value: String) {
    if run("/usr/libexec/PlistBuddy", ["-c", "Set :\(plistKey) \(value)", infoPlist], quiet: true).status != 0 {
        guard run("/usr/libexec/PlistBuddy", ["-c", "Add :\(plistKey) string \(value)", infoPlist]).status == 0 else {
            fail("could not write \(plistKey) to \(infoPlist)")
        }
    }
}

let arguments = CommandLine.arguments.dropFirst()
guard FileManager.default.fileExists(atPath: infoPlist) else { fail("run this from the repository root") }

switch arguments.first {
case "generate":
    if let existing = privateKey() {
        let publicKey = existing.publicKey.rawRepresentation.base64EncodedString()
        setPlistPublicKey(publicKey)
        print("A signing key already exists in the keychain. Public key (now in \(infoPlist)): \(publicKey)")
        exit(0)
    }
    let key = Curve25519.Signing.PrivateKey()
    // -T lets the security tool read the item later without a password prompt.
    let added = run("/usr/bin/security", [
        "add-generic-password", "-s", service, "-a", account, "-l", service,
        "-D", "Ed25519 private key", "-j", "Signs MiSTer FTP release archives. Back this up.",
        "-T", "/usr/bin/security", "-w", key.rawRepresentation.base64EncodedString(),
    ])
    guard added.status == 0, privateKey() != nil else { fail("could not save the key in the keychain") }
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    setPlistPublicKey(publicKey)
    print("Saved a new signing key in the login keychain as \"\(service)\".")
    print("Public key (now in \(infoPlist)): \(publicKey)")

case "sign":
    guard let path = arguments.dropFirst().first else { fail("usage: sign <file>") }
    guard let key = privateKey() else { fail("no signing key in the keychain. Run: swift scripts/update_signing.swift generate") }
    guard let expected = plistPublicKey() else { fail("\(infoPlist) has no \(plistKey). Run the generate command.") }
    guard key.publicKey.rawRepresentation.base64EncodedString() == expected else {
        fail("the keychain key does not match \(plistKey) in \(infoPlist); installed apps would reject this update")
    }
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    let signature = try key.signature(for: data)
    guard key.publicKey.isValidSignature(signature, for: data) else { fail("signature check failed") }
    let output = path + ".sig"
    try Data(signature.base64EncodedString().utf8).write(to: URL(fileURLWithPath: output))
    print("Signed \(output)")

case "check":
    guard let key = privateKey() else { fail("no signing key in the keychain") }
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    guard publicKey == plistPublicKey() else { fail("the keychain key does not match \(plistKey) in \(infoPlist)") }
    print("OK: the keychain key matches \(infoPlist). Public key: \(publicKey)")

default:
    fail("usage: swift scripts/update_signing.swift generate | sign <file> | check")
}
