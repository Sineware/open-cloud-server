import Vapor
public struct User: Content {
    let uuid: String
    let email: String
    let username: String
    let fullname: String
    let passhash: String
    let accesstoken: String
    let lastip: String?
    let id: Int
    let phone: String?
    var organizations: [Organization]?
}