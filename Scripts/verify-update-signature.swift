// Checks an update archive's EdDSA signature against the public key that
// installed apps carry (Packaging/Info.plist SUPublicEDKey), the same check
// Sparkle makes before installing. A release signed with any other key would
// be refused by every installed copy, so publishing stops here instead.
//
// Usage: swift Scripts/verify-update-signature.swift <public-key-base64> <archive> <signature-base64>
import CryptoKit
import Foundation

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("Usage: verify-update-signature.swift <public-key> <archive> <signature>\n".utf8))
    exit(64)
}
let values = Array(arguments)
guard let publicKeyData = Data(base64Encoded: values[0]),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
    FileHandle.standardError.write(Data("The public key is not a valid EdDSA key.\n".utf8))
    exit(1)
}
guard let signature = Data(base64Encoded: values[2]) else {
    FileHandle.standardError.write(Data("The signature is not valid base64.\n".utf8))
    exit(1)
}
guard let archive = FileManager.default.contents(atPath: values[1]) else {
    FileHandle.standardError.write(Data("Cannot read \(values[1]).\n".utf8))
    exit(1)
}
guard publicKey.isValidSignature(signature, for: archive) else {
    FileHandle.standardError.write(Data("The archive is not signed with the key installed apps trust.\n".utf8))
    exit(1)
}
print("The archive's signature matches the key installed apps trust.")
