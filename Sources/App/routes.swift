import Vapor
import PostgresNIO

struct WSMessageRawAction: Codable {
    let action: String
    let id: String?
}
struct WSMessage<PayloadType: Codable>: Codable {
    let id: String?
    let action: String
    let payload: PayloadType
}

// Payloads
public struct HelloPayload: Codable {
    let status: Bool
}
public struct HelloClientPayload: Codable {
    let clientType: String
    let accessToken: String
}
public struct PingPayload: Codable {
    let text: String?
}
public struct ErrorPayload: Codable {
    let msg: String
}
public struct DebugPayload: Codable {
    let dbVersion: String
    var version: String = "Sineware Open Cloud Server 2"
    var clientUUID: String?
    var clientName: String?
    var clientType: String?
    var currentRatePeriodRequestCount: Int
}
public struct RegisterPayload: Codable {
    let username: String
    let password: String
    let email: String
    let fullname: String
    let phone: String
}
public struct LoginPayload: Codable {
    let username: String
    let password: String
}
public struct GetSelfPayload: Codable {
}
public struct GetOrgPayload: Codable {
    let uuid: String
}
public struct GetOrgWebsitesPayload: Codable {
    let uuid: String
}

// {action: result payload: for: register, status: true}
public struct ResultPayload<T: Codable>: Content {
    let forAction: String
    let status: Bool
    let data: T?
}

public struct ClientState {
    let uuid: String
    let ws: WebSocket
    var name: String
    let type: String
}
// Client states
public var states: [String: ClientState] = [:]

func routes(_ app: Application) throws {
    app.get("update") { req -> EventLoopFuture<View> in
        return req.view.render(app.directory.publicDirectory + "update.html")
    }

    // AuthServer
    // register
    app.post("register") { req async throws -> ResultPayload<String> in
        let payload = try req.content.decode(RegisterPayload.self)
        print(payload)
        return ResultPayload(forAction: "register", status: true, data: nil)
    }
    // login
    app.post("login") { req async throws -> ResultPayload<String> in
        let db = try await connectDatabase()
        let payload = try req.content.decode(LoginPayload.self)
        let token = try await loginUser(db, payload.username, payload.password)
        try await db.close()
        return ResultPayload(forAction: "login", status: token != nil, data: token ?? "Invalid Username or Password")
    }


    // Update Services
    // Seperate administrative server will handle adding updates and serving files (OCS only needs to read)
    app.get("updates", "all") { req async throws -> [Update] in
        let db = try await connectDatabase()
        let res = try? await getAllUpdates(db)
        try await db.close()
        return res ?? []
    }
    app.get("updates", "by-uuid", ":uuid") { req async throws -> Update in
        let db = try await connectDatabase()
        let res = try? await getSingleUpdatebyUUID(db, req.parameters.get("uuid") ?? "")
        try await db.close()
        return res ?? Update(id: -1, uuid: "", product: "", variant: "", channel: "", buildnum: 0, buildstring: "", isreleased: false)
    }
    app.get("updates", ":product", ":variant", ":channel") { req async throws -> Update in
        let db = try await connectDatabase()
        let res = try? await getSingleUpdate(db, req.parameters.get("product") ?? "", req.parameters.get("variant") ?? "", req.parameters.get("channel") ?? "")
        try await db.close()
        return res ?? Update(id: -1, uuid: "", product: "", variant: "", channel: "", buildnum: 0, buildstring: "", isreleased: false)
    }

    app.webSocket("gateway") { req, ws async in
        print("New Websocket Connection from " + (req.peerAddress?.description ?? "Unknown Address"))
        let logger = Logger(label: (req.peerAddress?.description ?? "Unknown Address") + "-logger")
        print(ws)
        print("Connecting to PostgreSQL...")
        var uuid: String? = nil;
        var currentRatePeriodRequestCount: Int = 0;
        func getState(externalUUID: String? = nil) -> ClientState? {
            if(externalUUID != nil) {
                return states[externalUUID!]
            } else if(uuid != nil) {
                return states[uuid!]
            } else {
                return nil
            }
        }
        func isLoggedIn() -> Bool {
            return uuid != nil
        }

        do {
            let db = try await connectDatabase()
            ws.onText { ws, text async in
                currentRatePeriodRequestCount += 1;
                do {
                    // String received by this WebSocket.
                    print(text)
                    let msgData = text.data(using: .utf8)!
                    let action: String? = (try JSONDecoder().decode(WSMessageRawAction.self, from: msgData)).action
                    // if this request contains an ID, we should return it with any responses
                    let id: String? = (try JSONDecoder().decode(WSMessageRawAction.self, from: msgData)).id

                    // Unprotected actions
                    switch action {
                    case ACTION_PING:
                        let msg: WSMessage = try JSONDecoder().decode(WSMessage<PingPayload>.self, from: msgData)
                        await sendWSMessage(ws, ACTION_PONG, PingPayload(text: msg.payload.text), id)
                        return
                    case ACTION_DEBUG:
                        let dbVersion = try await getDBVersion(db)
                        let clientType: String? = getState()?.type
                        await sendWSMessage(ws, ACTION_RESULT, ResultPayload(forAction: ACTION_DEBUG, status: true, data: DebugPayload(dbVersion: dbVersion, clientType: clientType, currentRatePeriodRequestCount: currentRatePeriodRequestCount)), id)
                    case ACTION_HELLO:
                        let msg: WSMessage = try JSONDecoder().decode(WSMessage<HelloClientPayload>.self, from: msgData)
                        guard let user = try await getUserByAccessToken(db, msg.payload.accessToken) else {
                            // invalid access token
                            await sendWSMessage(ws, ACTION_RESULT, ResultPayload(forAction: ACTION_HELLO, status: false, data: ErrorPayload(msg: "Invalid Access Token")), id)
                            return
                        }
                        
                        states.updateValue(ClientState(uuid: user.uuid, ws: ws, name: user.username, type: msg.payload.clientType), forKey: user.uuid)
                        uuid = user.uuid;
                        // send result with user
                        await sendWSMessage(ws, ACTION_RESULT, ResultPayload(forAction: ACTION_HELLO, status: true, data: user), id)
                        //await sendWSMessage(ws, "login", user, id)
                    default:
                        // protected actions
                        guard isLoggedIn() else {
                            await sendWSError(ws, "Not Logged In")
                            return
                        }
                        switch action {
                        case ACTION_GET_SELF:
                            let user = try await getUserByUUID(db, uuid!)
                            await sendWSMessage(ws, ACTION_RESULT, ResultPayload(forAction: ACTION_GET_SELF, status: user != nil, data: user), id)
                        case ACTION_GET_ORG:
                            let msg: WSMessage = try JSONDecoder().decode(WSMessage<GetOrgPayload>.self, from: msgData)
                            // check if user is in the request organization
                            guard try await isUserInOrganization(db, uuid!, msg.payload.uuid) else {
                                await sendWSMessage(ws, ACTION_RESULT, ResultPayload(forAction: ACTION_GET_ORG, status: false, data: ErrorPayload(msg: "User is not in organization")), id)
                                return
                            }
                            guard let org = try await getOrganizationByUUID(db, uuid!) else {
                                await sendWSMessage(ws, ACTION_RESULT, ResultPayload(forAction: ACTION_GET_ORG, status: false, data: ErrorPayload(msg: "Organization not found")), id)
                                return
                            }
                            await sendWSMessage(ws, ACTION_RESULT, ResultPayload(forAction: ACTION_GET_ORG, status: true, data: org), id)
                        case ACTION_GET_ORG_WEBSITES:
                            let msg: WSMessage = try JSONDecoder().decode(WSMessage<GetOrgWebsitesPayload>.self, from: msgData)
                            // check if user is in the request organization
                            guard try await isUserInOrganization(db, uuid!, msg.payload.uuid) else {
                                await sendWSMessage(ws, ACTION_RESULT, ResultPayload(forAction: ACTION_GET_ORG_WEBSITES, status: false, data: ErrorPayload(msg: "User is not in organization")), id)
                                return
                            }
                            let websites = try await getOrganizationWebsites(db, msg.payload.uuid)
                            await sendWSMessage(ws, ACTION_RESULT, ResultPayload(forAction: ACTION_GET_ORG_WEBSITES, status: true, data: websites), id)
                        default:
                            await sendWSError(ws, "Invalid Action")
                            return
                        }
                    }
                } catch {
                    print("Error handling WS message: \(error)")
                    await sendWSError(ws, error.localizedDescription)
                }
            }
            await sendWSMessage(ws, ACTION_HELLO, HelloPayload(status: true))
            try await ws.onClose.get()
            try await db.close()
            logger.info("Client disconnected!")
        } catch {
            print("Explosion: \(error)")
            exit(-2)
        }
    }

}

func sendWSError(_ ws: WebSocket, _ error: String) async {
    let err = WSMessage<ErrorPayload>(id: nil, action: "error", payload: ErrorPayload(msg: error))
    try? await ws.send(String(data: (try! JSONEncoder().encode(err)), encoding: .utf8)!)
}
func sendWSMessage<PayloadType: Codable>(_ ws: WebSocket, _ action: String, _ payload: PayloadType, _ id: String? = nil) async {
    let msg = WSMessage<PayloadType>(id: id, action: action, payload: payload)
    try? await ws.send(String(data: (try! JSONEncoder().encode(msg)), encoding: .utf8)!)
}
