import Foundation
import SwiftGraphDB

/// Public umbrella for the SwiftGraphDB CloudKit reference adapter. Concrete types live in
/// neighbouring files so apps can import only what they need.
public enum SwiftGraphDBCloudKit {
    public static let zoneName = "SwiftGraphDB"
    public static let recordTypeNode = "GDB_Node"
    public static let recordTypeEdge = "GDB_Edge"
}
