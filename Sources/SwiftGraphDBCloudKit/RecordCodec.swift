import Foundation
import SwiftGraphDB

/// `GraphChange` ↔ `CloudKitRecord` codec. Adapter authors who want a different on-the-wire
/// shape can implement their own; this is the reference codec used by the reference transport.
public enum RecordCodec {

    public static func encode(_ change: GraphChange) throws -> CloudKitRecord {
        let recordID = CloudKitRecordID.make(from: change.entity)
        let recordType: String
        switch change.entity.kind {
        case .node: recordType = SwiftGraphDBCloudKit.recordTypeNode
        case .edge: recordType = SwiftGraphDBCloudKit.recordTypeEdge
        }
        var fields: [String: Data] = [:]
        let encoder = JSONEncoder()
        fields["change"] = try encoder.encode(change)
        fields["payloadFormat"] = try encoder.encode(change.payload?.format ?? .current)
        return CloudKitRecord(id: recordID, recordType: recordType, fields: fields)
    }

    public static func decode(_ record: CloudKitRecord) throws -> GraphChange {
        guard let blob = record.fields["change"] else {
            throw RecordCodecError.missingChangeField
        }
        let change = try JSONDecoder().decode(GraphChange.self, from: blob)
        if let format = change.payload?.format,
           format.major > PayloadFormatVersion.current.major {
            throw RecordCodecError.unsupportedPayloadFormat(found: format)
        }
        return change
    }
}

public enum RecordCodecError: Error, Equatable {
    case missingChangeField
    case unsupportedPayloadFormat(found: PayloadFormatVersion)
}
