import Vapor
public struct Website: Content {
    let id: Int
    let uuid: String
    let organization_id: Int
    let domain: String
    let type: String
    let name: String
}