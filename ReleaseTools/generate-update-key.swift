#!/usr/bin/env swift
import CryptoKit
import Foundation

let key = Curve25519.Signing.PrivateKey()
print("ASTER_UPDATE_PRIVATE_KEY=\(key.rawRepresentation.base64EncodedString())")
print("ASTER_UPDATE_PUBLIC_KEY=\(key.publicKey.rawRepresentation.base64EncodedString())")
