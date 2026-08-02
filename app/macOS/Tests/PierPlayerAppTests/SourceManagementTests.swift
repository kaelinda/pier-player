import Foundation
import CloudSyncKit
import DiagnosticsKit
import MediaSourceKit
import SMBSourceKit
import Testing
@testable import PierPlayerApp

@MainActor
@Test func restoredSourceWithoutCredentialRemainsVisibleForReconnect() async throws {
    let sourceStore = SourceManagementSourceStore()
    let source = SMBStorageSource(
        id: UUID(),
        displayName: "Synced NAS",
        host: "nas.local",
        share: "Media"
    )
    await sourceStore.add(source)
    let model = AppModel(
        credentialStore: SourceManagementCredentialStore(),
        sourceStore: sourceStore,
        sourceFactory: SourceManagementSourceFactory().makeSource
    )

    await model.restore()

    let configured = try #require(model.configuredSources.first)
    #expect(configured.id == source.id)
    #expect(configured.connectionState == .needsCredential)
    #expect(model.source(id: source.id) == nil)
}

@MainActor
@Test func sourceAddQueuesCloudSyncAfterLocalCommit() async throws {
    let coordinator = RecordingSyncCoordinator()
    let factory = SourceManagementSourceFactory()
    let model = AppModel(
        credentialStore: SourceManagementCredentialStore(),
        sourceStore: SourceManagementSourceStore(),
        sourceFactory: factory.makeSource,
        syncCoordinator: coordinator
    )

    try await model.addSMBSource(
        displayName: "Synced NAS",
        host: "nas.local",
        share: "Media",
        username: "viewer",
        password: "private-secret",
        domain: nil,
        requiresEncryption: true
    )

    let mutation = try #require(await coordinator.mutations.first)
    guard case let .upsertSource(source) = mutation else {
        Issue.record("Expected a source upsert")
        return
    }
    #expect(source.displayName == "Synced NAS")
    #expect(source.host == "nas.local")
    #expect(source.share == "Media")
}
@testable import SMBSourceKit

@MainActor
@Test func editingSourcePreservesPasswordAndReplacesTheLiveConnection() async throws {
    let fixture = try SourceManagementModelFixture()
    defer { fixture.cleanup() }
    let model = fixture.model

    try await model.addSMBSource(
        displayName: "Home NAS",
        host: "old.local",
        share: "Media",
        username: "viewer",
        password: "existing-secret",
        domain: nil,
        requiresEncryption: false
    )
    let sourceID = try #require(model.sources.first?.id)
    let originalSource = try #require(fixture.factory.sources.first)

    try await model.updateSMBSource(
        id: sourceID,
        displayName: "Living Room",
        host: "nas.local",
        share: "Movies",
        username: "editor",
        replacementPassword: nil,
        domain: "WORKGROUP",
        requiresEncryption: true
    )

    let connected = try #require(model.source(id: sourceID))
    #expect(connected.displayName == "Living Room")
    #expect(connected.configuration.host == "nas.local")
    #expect(connected.configuration.share == "Movies")
    #expect(connected.username == "editor")
    #expect(connected.configuration.domain == "WORKGROUP")
    #expect(connected.configuration.requiresEncryption)
    #expect(model.sourceRevision == 2)

    let credential = try #require(await fixture.credentialStore.load(sourceID: sourceID))
    #expect(credential.credential.username == "editor")
    #expect(credential.credential.password == "existing-secret")
    #expect(credential.domain == "WORKGROUP")

    let stored = try #require(await fixture.sourceStore.load().first)
    #expect(stored.id == sourceID)
    #expect(stored.displayName == "Living Room")
    let savedCredential = try #require(await fixture.credentialStore.load(sourceID: sourceID))
    #expect(savedCredential.credential.password == "existing-secret")
    #expect(await originalSource.disconnectCount == 1)
    #expect(await fixture.factory.sources.last?.connectCount == 1)
}

@MainActor
@Test func failedSourceEditKeepsTheExistingConnectionAndConfiguration() async throws {
    let fixture = try SourceManagementModelFixture()
    defer { fixture.cleanup() }
    let model = fixture.model

    try await model.addSMBSource(
        displayName: "Home NAS",
        host: "old.local",
        share: "Media",
        username: "viewer",
        password: "existing-secret",
        domain: nil,
        requiresEncryption: false
    )
    let sourceID = try #require(model.sources.first?.id)
    let originalSource = try #require(fixture.factory.sources.first)
    fixture.factory.nextConnectionError = MediaSourceError.unreachable(details: nil)

    await #expect(throws: MediaSourceError.unreachable(details: nil)) {
        try await model.updateSMBSource(
            id: sourceID,
            displayName: "Broken",
            host: "missing.local",
            share: "Movies",
            username: "viewer",
            replacementPassword: "replacement",
            domain: nil,
            requiresEncryption: false
        )
    }

    let connected = try #require(model.source(id: sourceID))
    #expect(connected.displayName == "Home NAS")
    #expect(connected.configuration.host == "old.local")
    #expect(model.sourceRevision == 1)
    #expect(await originalSource.disconnectCount == 0)
    #expect(await fixture.factory.sources.last?.disconnectCount == 1)

    let credential = try #require(await fixture.credentialStore.load(sourceID: sourceID))
    #expect(credential.credential.password == "existing-secret")
    let stored = try #require(await fixture.sourceStore.load().first)
    #expect(stored.displayName == "Home NAS")
}

@MainActor
@Test func metadataFailureRestoresCredentialsAndKeepsTheExistingSource() async throws {
    let fixture = try SourceManagementModelFixture()
    let model = fixture.model

    try await addExistingSource(to: model)
    let sourceID = try #require(model.sources.first?.id)
    let originalSource = try #require(fixture.factory.sources.first)
    await fixture.sourceStore.failNextUpdate()

    await #expect(throws: SMBSourceUpdateError.changesNotSaved) {
        try await updateExistingSource(id: sourceID, in: model)
    }

    let connected = try #require(model.source(id: sourceID))
    #expect(connected.displayName == "Home NAS")
    #expect(model.sourceRevision == 1)
    #expect(await originalSource.disconnectCount == 0)
    #expect(await fixture.factory.sources.last?.disconnectCount == 1)

    let credential = try #require(await fixture.credentialStore.load(sourceID: sourceID))
    #expect(credential.credential.username == "viewer")
    #expect(credential.credential.password == "existing-secret")
    let stored = try #require(await fixture.sourceStore.load().first)
    #expect(stored.displayName == "Home NAS")
}

@MainActor
@Test func credentialFailureRollsBackMetadataWithoutReplacingTheLiveSource() async throws {
    let fixture = try SourceManagementModelFixture()
    let model = fixture.model

    try await addExistingSource(to: model)
    let sourceID = try #require(model.sources.first?.id)
    let originalSource = try #require(fixture.factory.sources.first)
    await fixture.credentialStore.failSave(afterSuccessfulSaves: 0, failureCount: 1)

    await #expect(throws: SMBSourceUpdateError.changesNotSaved) {
        try await updateExistingSource(id: sourceID, in: model)
    }

    #expect(model.source(id: sourceID)?.displayName == "Home NAS")
    #expect(model.sourceRevision == 1)
    #expect(await originalSource.disconnectCount == 0)
    #expect(await fixture.factory.sources.last?.disconnectCount == 1)
    let stored = try #require(await fixture.sourceStore.load().first)
    #expect(stored.displayName == "Home NAS")
}

@MainActor
@Test func restoreUsesCredentialPreservedByMetadataRollback() async throws {
    let fixture = try SourceManagementModelFixture()
    let model = fixture.model

    try await addExistingSource(to: model)
    let sourceID = try #require(model.sources.first?.id)
    await fixture.credentialStore.failSave(afterSuccessfulSaves: 0, failureCount: 1)

    await #expect(throws: SMBSourceUpdateError.changesNotSaved) {
        try await updateExistingSource(id: sourceID, in: model)
    }

    let staleCredential = try #require(await fixture.credentialStore.load(sourceID: sourceID))
    #expect(staleCredential.credential.username == "viewer")
    #expect(staleCredential.credential.password == "existing-secret")
    #expect(staleCredential.domain == nil)

    let recoveryFactory = SourceManagementSourceFactory()
    let recoveredModel = AppModel(
        credentialStore: fixture.credentialStore,
        sourceStore: fixture.sourceStore,
        sourceFactory: recoveryFactory.makeSource
    )

    await recoveredModel.restore()

    let recoveredCredential = try #require(await fixture.credentialStore.load(sourceID: sourceID))
    #expect(recoveredCredential.credential.username == "viewer")
    #expect(recoveredCredential.credential.password == "existing-secret")
    #expect(recoveredCredential.domain == nil)
    #expect(recoveryFactory.credentials.last?.username == "viewer")
    #expect(recoveryFactory.credentials.last?.password == "existing-secret")
    #expect(recoveredModel.source(id: sourceID)?.displayName == "Home NAS")
    #expect(await recoveryFactory.sources.last?.connectCount == 1)
}

@MainActor
@Test func retryAfterCredentialFailurePreservesTheActivePassword() async throws {
    let fixture = try SourceManagementModelFixture()
    let model = fixture.model

    try await addExistingSource(to: model)
    let sourceID = try #require(model.sources.first?.id)
    await fixture.credentialStore.failSave(afterSuccessfulSaves: 0, failureCount: 1)

    await #expect(throws: SMBSourceUpdateError.changesNotSaved) {
        try await updateExistingSource(id: sourceID, in: model)
    }

    try await model.updateSMBSource(
        id: sourceID,
        displayName: "Living Room",
        host: "nas.local",
        share: "Movies",
        username: "editor",
        replacementPassword: nil,
        domain: "WORKGROUP",
        requiresEncryption: true
    )

    #expect(fixture.factory.credentials.last?.password == "existing-secret")
    let credential = try #require(await fixture.credentialStore.load(sourceID: sourceID))
    #expect(credential.credential.password == "existing-secret")
    let stored = try #require(await fixture.sourceStore.load().first)
    #expect(stored.id == sourceID)
}

@MainActor
@Test func restoreTreatsKeychainAsTheCredentialAuthority() async throws {
    let fixture = try SourceManagementModelFixture()
    let model = fixture.model

    try await addExistingSource(to: model)
    let sourceID = try #require(model.sources.first?.id)
    try await fixture.credentialStore.save(
        sourceID: sourceID,
        credential: SMBCredential(username: "editor", password: "replacement"),
        domain: "WORKGROUP"
    )
    let firstRecoveryFactory = SourceManagementSourceFactory()
    let firstRecoveredModel = AppModel(
        credentialStore: fixture.credentialStore,
        sourceStore: fixture.sourceStore,
        sourceFactory: firstRecoveryFactory.makeSource
    )

    await firstRecoveredModel.restore()

    #expect(firstRecoveredModel.source(id: sourceID)?.displayName == "Home NAS")
    #expect(firstRecoveryFactory.credentials.last?.username == "editor")
    #expect(firstRecoveryFactory.credentials.last?.password == "replacement")
    #expect(await firstRecoveryFactory.sources.last?.connectCount == 1)
    let staleCredential = try #require(await fixture.credentialStore.load(sourceID: sourceID))
    #expect(staleCredential.credential.username == "editor")
    #expect(staleCredential.credential.password == "replacement")

    let secondRecoveryFactory = SourceManagementSourceFactory()
    let secondRecoveredModel = AppModel(
        credentialStore: fixture.credentialStore,
        sourceStore: fixture.sourceStore,
        sourceFactory: secondRecoveryFactory.makeSource
    )

    await secondRecoveredModel.restore()

    let recoveredCredential = try #require(await fixture.credentialStore.load(sourceID: sourceID))
    #expect(recoveredCredential.credential.username == "editor")
    #expect(recoveredCredential.credential.password == "replacement")
}

@MainActor
@Test func transientCredentialRollbackFailureIsRetried() async throws {
    let fixture = try SourceManagementModelFixture()
    let model = fixture.model

    try await addExistingSource(to: model)
    let sourceID = try #require(model.sources.first?.id)
    await fixture.sourceStore.failNextUpdate()
    await fixture.credentialStore.failSave(afterSuccessfulSaves: 1, failureCount: 1)

    await #expect(throws: SMBSourceUpdateError.changesNotSaved) {
        try await updateExistingSource(id: sourceID, in: model)
    }

    let credential = try #require(await fixture.credentialStore.load(sourceID: sourceID))
    #expect(credential.credential.username == "viewer")
    #expect(credential.credential.password == "existing-secret")
}

@MainActor
@Test func removingSourceDeletesPersistentStateBeforeDisconnecting() async throws {
    let fixture = try SourceManagementModelFixture()
    let model = fixture.model

    try await addExistingSource(to: model)
    let sourceID = try #require(model.sources.first?.id)
    let source = try #require(fixture.factory.sources.first)

    try await model.removeSource(id: sourceID)

    #expect(model.source(id: sourceID) == nil)
    #expect(model.sourceRevision == 2)
    #expect(await fixture.sourceStore.load().isEmpty)
    #expect(await fixture.credentialStore.load(sourceID: sourceID) == nil)
    #expect(await source.disconnectCount == 1)
}

@MainActor
@Test func sourceMetadataRemovalFailureKeepsTheLiveSourceAndCredentials() async throws {
    let fixture = try SourceManagementModelFixture()
    let model = fixture.model

    try await addExistingSource(to: model)
    let sourceID = try #require(model.sources.first?.id)
    let source = try #require(fixture.factory.sources.first)
    await fixture.sourceStore.failNextRemove()

    await #expect(throws: SMBSourceRemovalError.changesNotSaved) {
        try await model.removeSource(id: sourceID)
    }

    #expect(model.source(id: sourceID) != nil)
    #expect(model.sourceRevision == 1)
    #expect(await fixture.sourceStore.load().count == 1)
    #expect(await fixture.credentialStore.load(sourceID: sourceID) != nil)
    #expect(await source.disconnectCount == 0)
}

@MainActor
@Test func credentialRemovalFailureRestoresMetadataAndKeepsTheLiveSource() async throws {
    let fixture = try SourceManagementModelFixture()
    let model = fixture.model

    try await addExistingSource(to: model)
    let sourceID = try #require(model.sources.first?.id)
    let source = try #require(fixture.factory.sources.first)
    await fixture.credentialStore.failNextDelete()

    await #expect(throws: SMBSourceRemovalError.changesNotSaved) {
        try await model.removeSource(id: sourceID)
    }

    #expect(model.source(id: sourceID) != nil)
    #expect(model.sourceRevision == 1)
    #expect(await fixture.sourceStore.load().count == 1)
    #expect(await fixture.credentialStore.load(sourceID: sourceID) != nil)
    #expect(await source.disconnectCount == 0)
}

@MainActor
@Test func credentialRollbackFailureIsReportedWithoutDisconnectingTheSource() async throws {
    let fixture = try SourceManagementModelFixture()
    let model = fixture.model

    try await addExistingSource(to: model)
    let sourceID = try #require(model.sources.first?.id)
    let source = try #require(fixture.factory.sources.first)
    await fixture.sourceStore.failNextRemove()
    await fixture.credentialStore.failSave(afterSuccessfulSaves: 0, failureCount: 1)

    await #expect(throws: SMBSourceRemovalError.credentialRollbackFailed) {
        try await model.removeSource(id: sourceID)
    }

    #expect(model.source(id: sourceID) != nil)
    #expect(model.sourceRevision == 1)
    #expect(await fixture.sourceStore.load().count == 1)
    #expect(await fixture.credentialStore.load(sourceID: sourceID) == nil)
    #expect(await source.disconnectCount == 0)
    #expect(
        AppModel.connectionErrorMessage(for: SMBSourceRemovalError.credentialRollbackFailed)
            == "The source was not removed, and its saved credentials could not be restored."
    )
}

@MainActor
private func addExistingSource(to model: AppModel) async throws {
    try await model.addSMBSource(
        displayName: "Home NAS",
        host: "old.local",
        share: "Media",
        username: "viewer",
        password: "existing-secret",
        domain: nil,
        requiresEncryption: false
    )
}

@MainActor
private func updateExistingSource(id: UUID, in model: AppModel) async throws {
    try await model.updateSMBSource(
        id: id,
        displayName: "Living Room",
        host: "nas.local",
        share: "Movies",
        username: "editor",
        replacementPassword: "replacement",
        domain: "WORKGROUP",
        requiresEncryption: true
    )
}

@MainActor
private final class SourceManagementModelFixture {
    let sourceStore = SourceManagementSourceStore()
    let credentialStore = SourceManagementCredentialStore()
    let factory = SourceManagementSourceFactory()
    let model: AppModel

    init() throws {
        model = AppModel(
            credentialStore: credentialStore,
            sourceStore: sourceStore,
            sourceFactory: factory.makeSource
        )
    }

    func cleanup() {}
}

private actor SourceManagementCredentialStore: SMBCredentialStore {
    private var credentials: [UUID: StoredSMBCredential] = [:]
    private var successfulSavesBeforeFailure: Int?
    private var remainingSaveFailures = 0
    private var shouldFailNextDelete = false

    func save(sourceID: UUID, credential: SMBCredential, domain: String?) throws {
        if let successfulSavesBeforeFailure {
            guard successfulSavesBeforeFailure > 0 else {
                remainingSaveFailures -= 1
                if remainingSaveFailures == 0 {
                    self.successfulSavesBeforeFailure = nil
                }
                throw SourceManagementPersistenceError.saveFailed
            }
            self.successfulSavesBeforeFailure = successfulSavesBeforeFailure - 1
        }
        credentials[sourceID] = StoredSMBCredential(
            credential: credential,
            domain: domain
        )
    }

    func load(sourceID: UUID) -> StoredSMBCredential? {
        credentials[sourceID]
    }

    func delete(sourceID: UUID) throws {
        if shouldFailNextDelete {
            shouldFailNextDelete = false
            throw SourceManagementPersistenceError.saveFailed
        }
        credentials[sourceID] = nil
    }

    func failSave(afterSuccessfulSaves count: Int, failureCount: Int) {
        successfulSavesBeforeFailure = count
        remainingSaveFailures = failureCount
    }

    func failNextDelete() {
        shouldFailNextDelete = true
    }
}

private actor RecordingSyncCoordinator: CloudSyncCoordinating {
    private(set) var mutations: [CloudSyncMutation] = []

    func enqueue(_ mutation: CloudSyncMutation) {
        mutations.append(mutation)
    }

    func synchronize(local: CloudSyncSnapshot) -> CloudSyncSnapshot {
        local
    }
}

private actor SourceManagementSourceStore: SMBSourceStoring {
    private var sources: [SMBStorageSource] = []
    private var shouldFailNextUpdate = false
    private var shouldFailNextRemove = false

    func load() -> [SMBStorageSource] {
        sources
    }

    func save(_ sources: [SMBStorageSource]) {
        self.sources = sources
    }

    func add(_ source: SMBStorageSource) {
        sources.append(source)
    }

    func update(_ source: SMBStorageSource) throws {
        if shouldFailNextUpdate {
            shouldFailNextUpdate = false
            throw SourceManagementPersistenceError.saveFailed
        }
        guard let index = sources.firstIndex(where: { $0.id == source.id }) else {
            throw SMBSourceStoreError.sourceNotFound(source.id)
        }
        sources[index] = source
    }

    func remove(id: UUID) throws {
        if shouldFailNextRemove {
            shouldFailNextRemove = false
            throw SourceManagementPersistenceError.saveFailed
        }
        sources.removeAll { $0.id == id }
    }

    func failNextUpdate() {
        shouldFailNextUpdate = true
    }

    func failNextRemove() {
        shouldFailNextRemove = true
    }
}

private enum SourceManagementPersistenceError: Error {
    case saveFailed
}

@MainActor
private final class SourceManagementSourceFactory {
    var sources: [SourceManagementTestSource] = []
    var credentials: [SMBCredential] = []
    var nextConnectionError: MediaSourceError?

    func makeSource(
        configuration: SMBConnectionConfiguration,
        credential: SMBCredential
    ) -> any MediaSource {
        let source = SourceManagementTestSource(
            id: configuration.sourceID,
            displayName: configuration.displayName,
            connectionError: nextConnectionError
        )
        nextConnectionError = nil
        sources.append(source)
        credentials.append(credential)
        return source
    }
}

private actor SourceManagementTestSource: MediaSource {
    nonisolated let id: UUID
    nonisolated let displayName: String
    private let connectionError: MediaSourceError?
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0

    init(id: UUID, displayName: String, connectionError: MediaSourceError?) {
        self.id = id
        self.displayName = displayName
        self.connectionError = connectionError
    }

    func connect() throws {
        connectCount += 1
        if let connectionError { throw connectionError }
    }

    func disconnect() {
        disconnectCount += 1
    }

    func list(directory path: String) throws -> [MediaSourceItem] {
        []
    }

    func open(file path: String) throws -> any MediaReadableFile {
        throw MediaSourceError.unsupported(reason: "Not needed")
    }
}
