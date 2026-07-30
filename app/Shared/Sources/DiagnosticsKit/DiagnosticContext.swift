import Foundation

public struct DiagnosticContext: Codable, Equatable, Hashable, Sendable {
    public let appRunID: UUID
    public let activityID: UUID
    public let operationID: UUID
    public let parentOperationID: UUID?

    public init(
        appRunID: UUID,
        activityID: UUID,
        operationID: UUID,
        parentOperationID: UUID? = nil
    ) {
        self.appRunID = appRunID
        self.activityID = activityID
        self.operationID = operationID
        self.parentOperationID = parentOperationID
    }

    public func child(operationID: UUID = UUID()) -> DiagnosticContext {
        DiagnosticContext(
            appRunID: appRunID,
            activityID: activityID,
            operationID: operationID,
            parentOperationID: self.operationID
        )
    }
}
