import Vapor
public struct Update: Content {
    let id: Int
    let uuid: String
    let product: String
    let variant: String
    let channel: String
    let buildnum: Int
    let buildstring: String
    let isreleased: Bool
    let url: String
    let jwt: String
    let arch: String
}