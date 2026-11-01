import StratovoCore
import Foundation
import Security

/// Only credentials explicitly saved by the user, scoped to this data folder.
enum WindowsSetupKeychain {
    struct Credential: Codable {
        let name: String
        let password: String
    }
    private static func query(storageID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "org.pwnedg0blin.openguest.windows.setup",
         kSecAttrAccount as String: storageID]
    }
    static func save(_ credential: Credential, storageID: String) throws {
        let base = query(storageID: storageID)
        let data = try JSONEncoder().encode(credential)
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrLabel as String: L10n.text("Stratovo · Windows-Einrichtung")]
        var result = SecItemUpdate(base as CFDictionary, values as CFDictionary)
        if result == errSecItemNotFound {
            result = SecItemAdd(base.merging(values) { _, new in new } as CFDictionary, nil)
        }
        guard result == errSecSuccess else { throw failure(result) }
        // Report success only after the exact stored value can be read back.
        guard let stored = try load(storageID: storageID), stored.name == credential.name,
              stored.password == credential.password else { throw failure(errSecDecode) }
    }
    static func load(storageID: String, allowInteraction: Bool = true) throws -> Credential? {
        var request = query(storageID: storageID)
        request[kSecReturnData as String] = true
        if !allowInteraction { request[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw failure(status) }
        guard let data = result as? Data else { throw failure(errSecDecode) }
        return try JSONDecoder().decode(Credential.self, from: data)
    }
    static func remove(storageID: String) throws {
        let status = SecItemDelete(query(storageID: storageID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }
    private static func failure(_ status: OSStatus) -> NSError {
        let message: String
        if status == errSecUserCanceled || status == errSecAuthFailed {
            message = L10n.text("Der macOS-Schlüsselbundzugriff wurde nicht freigegeben. Beim Laden das Kennwort deines Mac-Anmeldeschlüsselbunds verwenden (normalerweise dein Mac-Anmeldekennwort) und den Zugriff erlauben. Deine bisherigen Eingaben bleiben erhalten.")
        } else if status == errSecInteractionNotAllowed {
            message = L10n.text("Gespeicherte Kontodaten benötigen eine macOS-Freigabe. Bitte „Aus Schlüsselbund laden“ wählen.")
        } else {
            message = L10n.message("Schlüsselbund: \(SecCopyErrorMessageString(status, nil) as String? ?? "Zugriff fehlgeschlagen")")
        }
        return NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
    }
}
