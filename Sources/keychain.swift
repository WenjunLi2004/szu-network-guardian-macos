import Foundation
import Security

enum KeychainError: Error {
    case usage
    case status(OSStatus)
}

func baseQuery(_ service: String) -> [CFString: Any] {
    return [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: service,
        kSecAttrAccount: "credential",
    ]
}

func setSecret(_ service: String, _ data: Data) throws {
    guard !data.isEmpty else { throw KeychainError.usage }
    let query = baseQuery(service)
    let update: [CFString: Any] = [kSecValueData: data]
    let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    if updateStatus == errSecSuccess { return }
    if updateStatus != errSecItemNotFound { throw KeychainError.status(updateStatus) }
    var add = query
    add[kSecValueData] = data
    let addStatus = SecItemAdd(add as CFDictionary, nil)
    if addStatus != errSecSuccess { throw KeychainError.status(addStatus) }
}

func getSecret(_ service: String) throws -> Data {
    var query = baseQuery(service)
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else {
        throw KeychainError.status(status)
    }
    return data
}

func deleteSecret(_ service: String) throws {
    let status = SecItemDelete(baseQuery(service) as CFDictionary)
    if status != errSecSuccess && status != errSecItemNotFound {
        throw KeychainError.status(status)
    }
}

do {
    guard CommandLine.arguments.count == 3 else { throw KeychainError.usage }
    let action = CommandLine.arguments[1]
    let service = CommandLine.arguments[2]
    switch action {
    case "set":
        try setSecret(service, FileHandle.standardInput.readDataToEndOfFile())
    case "get":
        FileHandle.standardOutput.write(try getSecret(service))
    case "delete":
        try deleteSecret(service)
    default:
        throw KeychainError.usage
    }
} catch {
    fputs("Keychain operation failed.\\n", stderr)
    exit(1)
}
