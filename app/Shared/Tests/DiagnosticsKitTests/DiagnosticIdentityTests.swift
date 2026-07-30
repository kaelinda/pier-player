import Foundation
import Testing
@testable import DiagnosticsKit

@Test func hmacIdentityIsStableOpaqueAndMetadataSensitive() {
    let provider = HMACDiagnosticIdentityProvider(keyData: Data(repeating: 0x2A, count: 32))
    let sourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!

    let first = provider.fileIdentity(
        sourceID: sourceID,
        normalizedPath: "/private/customer/movie.mp4",
        size: 100,
        modifiedAt: Date(timeIntervalSince1970: 1)
    )
    let second = provider.fileIdentity(
        sourceID: sourceID,
        normalizedPath: "/private/customer/movie.mp4",
        size: 100,
        modifiedAt: Date(timeIntervalSince1970: 1)
    )
    let changed = provider.fileIdentity(
        sourceID: sourceID,
        normalizedPath: "/private/customer/movie.mp4",
        size: 101,
        modifiedAt: Date(timeIntervalSince1970: 1)
    )

    #expect(first == second)
    #expect(first.stability == .stable)
    #expect(first.value.count == 64)
    #expect(first.value.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    #expect(first != changed)
    #expect(!first.value.contains("private"))
    #expect(!first.value.contains("customer"))
    #expect(!first.value.contains("movie"))
}

@Test func unavailablePersistentKeyUsesStablePerRunFallback() {
    let provider = HMACDiagnosticIdentityProvider(keyStore: FailingIdentityKeyStore())
    let sourceID = UUID()

    let first = provider.fileIdentity(
        sourceID: sourceID,
        normalizedPath: "/movie.mp4",
        size: 100,
        modifiedAt: nil
    )
    let second = provider.fileIdentity(
        sourceID: sourceID,
        normalizedPath: "/movie.mp4",
        size: 100,
        modifiedAt: nil
    )

    #expect(first == second)
    #expect(first.stability == .transient)
    #expect(first.value.count == 64)
}

private struct FailingIdentityKeyStore: DiagnosticIdentityKeyStore {
    func loadOrCreateKey() throws -> Data {
        throw TestKeyError.unavailable
    }
}

private enum TestKeyError: Error {
    case unavailable
}
