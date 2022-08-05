import Vapor
public struct Organization: Content {
    let id: Int
    let uuid: String
    let name: String
    let tier: String
}