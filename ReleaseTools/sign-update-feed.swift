#!/usr/bin/env swift
import CryptoKit
import Foundation

struct Envelope: Encodable {
    let payload: String
    let signature: String
}

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("Usage: sign-update-feed.swift RELEASE.json SIGNED-FEED.json\n".utf8))
    exit(64)
}
guard let encodedKey = ProcessInfo.processInfo.environment["ASTER_UPDATE_PRIVATE_KEY"],
      let keyData = Data(base64Encoded: encodedKey),
      let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) else {
    FileHandle.standardError.write(Data("ASTER_UPDATE_PRIVATE_KEY must contain a valid base64 Ed25519 private key.\n".utf8))
    exit(78)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
let payload = try Data(contentsOf: inputURL)
_ = try JSONSerialization.jsonObject(with: payload)
let signature = try privateKey.signature(for: payload)
let envelope = Envelope(
    payload: payload.base64EncodedString(),
    signature: signature.base64EncodedString()
)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
try encoder.encode(envelope).write(to: outputURL, options: .atomic)
print("Signed feed: \(outputURL.path)")
print("Public key: \(privateKey.publicKey.rawRepresentation.base64EncodedString())")
