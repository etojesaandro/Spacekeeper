import Foundation
import Security

/// A cloud access token of the user, kept in the device keychain.
struct KeychainToken: Sendable {
  private let service: String

  /// - Parameter service: Name the token is filed under, one per cloud.
  init(service: String) {
    self.service = service
  }

  /// The token kept earlier; fails when none is kept.
  func value() throws -> String {
    var found: CFTypeRef?
    let status = SecItemCopyMatching(
      [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecReturnData: true,
        kSecMatchLimit: kSecMatchLimitOne,
      ] as CFDictionary,
      &found
    )
    guard status == errSecSuccess, let data = found as? Data, !data.isEmpty else {
      throw NoToken()
    }
    return String(decoding: data, as: UTF8.self)
  }

  /// Throws away the token kept before, if any.
  func forget() {
    SecItemDelete(
      [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
      ] as CFDictionary
    )
  }

  /// Keeps the token, replacing the one kept before.
  func keep(_ token: String) throws {
    forget()
    let status = SecItemAdd(
      [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        kSecValueData: Data(token.utf8),
      ] as CFDictionary,
      nil
    )
    guard status == errSecSuccess else {
      throw KeychainFailure(status: status)
    }
  }
}

/// Nobody is signed in yet.
struct NoToken: LocalizedError {
  var errorDescription: String? {
    "Sign in to Yandex Disk first, with the account button"
  }
}

/// The keychain refused to keep a token.
struct KeychainFailure: LocalizedError {
  private let status: OSStatus

  init(status: OSStatus) {
    self.status = status
  }

  var errorDescription: String? {
    "The keychain refused to keep the token (status \(status))"
  }
}
