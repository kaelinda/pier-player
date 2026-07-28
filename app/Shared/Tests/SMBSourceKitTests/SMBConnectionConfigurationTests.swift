import Foundation
import Testing
@testable import SMBSourceKit

@Suite struct SMBConnectionConfigurationTests {
    @Test func normalizesConnectionSettings() throws {
        let sourceID = UUID()
        let configuration = try SMBConnectionConfiguration(
            sourceID: sourceID,
            displayName: "  Living Room NAS  ",
            host: "  smb://nas.local  ",
            share: "  Media  ",
            domain: "  WORKGROUP  ",
            requiresEncryption: true
        )

        #expect(configuration.sourceID == sourceID)
        #expect(configuration.displayName == "Living Room NAS")
        #expect(configuration.host == "nas.local")
        #expect(configuration.share == "Media")
        #expect(configuration.domain == "WORKGROUP")
        #expect(configuration.requiresEncryption)
    }

    @Test func normalizesAnEmptyDomainToNil() throws {
        let configuration = try SMBConnectionConfiguration(
            displayName: "NAS",
            host: "nas.local",
            share: "Media",
            domain: "   "
        )

        #expect(configuration.domain == nil)
        #expect(!configuration.requiresEncryption)
    }

    @Test(arguments: [
        "",
        "   ",
        "smb://nas.local/Media",
        "nas.local/Media",
        "nas.local:445",
        "user@nas.local",
    ])
    func rejectsInvalidHosts(_ host: String) {
        #expect(throws: SMBConfigurationError.self) {
            try SMBConnectionConfiguration(
                displayName: "NAS",
                host: host,
                share: "Media"
            )
        }
    }

    @Test(arguments: ["", "   ", "Media/Movies", "Media\\Movies"])
    func rejectsInvalidShares(_ share: String) {
        #expect(throws: SMBConfigurationError.self) {
            try SMBConnectionConfiguration(
                displayName: "NAS",
                host: "nas.local",
                share: share
            )
        }
    }

    @Test func credentialRejectsAnEmptyUsername() {
        #expect(throws: SMBConfigurationError.self) {
            try SMBCredential(username: "   ", password: "secret")
        }
    }

    @Test func credentialTrimsUsernameWithoutChangingPassword() throws {
        let credential = try SMBCredential(
            username: "  viewer  ",
            password: "  exact secret  "
        )

        #expect(credential.username == "viewer")
        #expect(credential.password == "  exact secret  ")
    }

    @Test func rootAndRelativeChildrenProduceAbsolutePaths() throws {
        let root = try SMBPath("/")
        let child = try root.appending("Movies/Feature Film.mkv")

        #expect(root.string == "/")
        #expect(child.string == "/Movies/Feature Film.mkv")
    }

    @Test func pathNormalizationRemovesDuplicateSeparatorsAndDots() throws {
        let path = try SMBPath("//Movies/./Action//film.mkv/")

        #expect(path.string == "/Movies/Action/film.mkv")
    }

    @Test(arguments: ["../secret", "/Movies/../secret", "Movies\\secret"])
    func rejectsTraversalAndBackslashes(_ path: String) {
        #expect(throws: SMBConfigurationError.self) {
            try SMBPath(path)
        }
    }
}
