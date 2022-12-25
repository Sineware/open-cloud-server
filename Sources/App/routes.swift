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
public struct HelloDevicePayload: Codable {
    let clientType: String
    let accessToken: String
    let uuid: String
    let name: String?
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
    let totp: String?
}
public struct GetSelfPayload: Codable {
}
public struct GetOrgPayload: Codable {
    let uuid: String
}
public struct GetOrgWebsitesPayload: Codable {
    let uuid: String
}
public struct CreateOrgPayload: Codable {
    let name: String
    let description: String
    let website: String
    let logo: String
}

// router
public struct RouterClientRegisterPortPayload: Codable {
    let port: Int
    let proto: String
    let name: String
    // set when sending to server, storing in routerPortMappings, and sending back to client in result
    let publicPort: Int?
    let clientUUID: String?
}
public struct RouterClientUnregisterPortPayload: Codable {
    let port: Int
}
public struct RouterPassPacketPayload: Codable {
    let publicPort: Int
    let connectionID: String
    let sequence: Int
    let data: String
}
public struct RouterConnectionDisconnectedPayload: Codable {
    let connectionID: String
    let publicPort: Int
}

// extension service WS message container
public struct ExtensionServiceWSMessageContainer: Codable {
    let clientUUID: String
    let msg: String
}

// {action: result payload: for: register, status: true}
public struct ResultPayload<T: Codable>: Content {
    let forAction: String
    let status: Bool
    let data: T?
}

// KeyCloak
public struct TokenResponse: Codable {
    let access_token: String?
    let expires_in: Int?
    let refresh_expires_in: Int?
    let refresh_token: String?
    let token_type: String?
    let id_token: String?
    let not_before_policy: Int?
    let session_state: String?
    let scope: String?
}
public struct UserInfoResponse: Codable {
    let sub: String
    let email_verified: Bool
    let name: String
    let preferred_username: String
    let given_name: String
    let family_name: String
    let email: String
}

// Client states
public struct ClientState {
    let uuid: String
    let ws: WebSocket
    var name: String
    let type: String
    var orgUUID: String?
}
public struct ClientStateCodable: Codable {
    let uuid: String
    var name: String
    let type: String
    var orgUUID: String?
}

public var states: [String: ClientState] = [:]
public var routerPortMappings: [Int: RouterClientRegisterPortPayload] = [:]

let pglogger = Logger(label: "postgres-logger")
func routes(_ app: Application) throws {
    app.get("update") { req -> EventLoopFuture<View> in
        return req.view.render(app.directory.publicDirectory + "update.html")
    }

    // AuthServer
    // register
    app.post("register") { req async throws -> ResultPayload<RegisterPayload> in
        let payload = try req.content.decode(RegisterPayload.self)
        print(payload)
        return ResultPayload<RegisterPayload>(forAction: "register", status: true, data: payload)
    }
    // login
    app.post("login") { req async throws -> ResultPayload<String> in
        // Make a POST request to id.sineware.ca
        let loginPayload = try req.content.decode(LoginPayload.self)
        let url = Environment.get("KEYCLOAK_URL")!
        let loginResponse = try await req.client.post(URI(stringLiteral: url + "token")) { loginRequest in
            loginRequest.headers.add(name: "Content-Type", value: "application/x-www-form-urlencoded")
            let secret = Environment.get("KEYCLOAK_SECRET")!
            loginRequest.body = .init(string: 
                "grant_type=password&client_id=\(Environment.get("KEYCLOAK_CLIENT_ID")!)&client_secret=\(secret)&username=\(loginPayload.username)&password=\(loginPayload.password)&totp=\(loginPayload.totp ?? "")&scope=openid profile email"
            )
        }
        print(loginResponse)
        if(loginResponse.status == .ok) {
            let tokenResponse = try loginResponse.content.decode(TokenResponse.self)
            // Get user info
            let userInfoResponse = try await req.client.get(URI(stringLiteral: url + "userinfo")) { userInfoRequest in
                userInfoRequest.headers.add(name: "Authorization", value: " Bearer \(tokenResponse.access_token ?? "")")
            }
            print(userInfoResponse)
            if(userInfoResponse.status == .ok) {
                let userInfo = try userInfoResponse.content.decode(UserInfoResponse.self)
                let db = try await connectDatabase()
                do {
                    try await loginUserWithKeycloak(db, userInfo, tokenResponse)
                    try await db.close()
                return ResultPayload(forAction: "login", status: true, data: tokenResponse.access_token)
                } catch {
                    print("Error in login with keycloak")
                    print(error)
                    try await db.close()
                    return ResultPayload(forAction: "login", status: false, data: "An internal error has occurred, please try again later, or contact support if the problem persists.")
                }
                
            } else {
                return ResultPayload(forAction: "login", status: false, data: "Failed to get user info, please try again later, or contact support if the problem persists.")
            }
        } else {
            return ResultPayload(forAction: "login", status: false, data: "Invalid Username, Password or TOTP code.")
        }
    }


    // Update Services
    // Separate administrative server will handle adding updates and serving files (OCS only needs to read)
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

    // Webhook
    app.get("webhook") { req async throws -> String in
        return "Hello, world!"
    }

    // OCS2 Websocket Gateway
    var routerServiceWS: WebSocket? = nil;
    var extensionServiceWS: WebSocket? = nil;
    app.webSocket("gateway", maxFrameSize: .init(integerLiteral: 1 << 24)) { req, ws async in
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
                    //print(text)
                    let msgData = text.data(using: .utf8)!
                    let action: String? = (try JSONDecoder().decode(WSMessageRawAction.self, from: msgData)).action
                    // if this request contains an ID, we should return it with any responses
                    let id: String? = (try JSONDecoder().decode(WSMessageRawAction.self, from: msgData)).id

                    if(action != ACTION_ROUTER_PASS_PACKET && action! != ACTION_PING) {
                        print(text)
                    }

                    // Unprotected actions
                    switch action {
                    case ACTION_PING:
                        let msg: WSMessage = try JSONDecoder().decode(WSMessage<PingPayload>.self, from: msgData)
                        await sendWSMessage(ws, ACTION_RESULT, ResultPayload(forAction: ACTION_PING, status: true, data: msg.payload.text), id)
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
                    case ACTION_DEVICE_HELLO:
                        let msg: WSMessage = try JSONDecoder().decode(WSMessage<HelloDevicePayload>.self, from: msgData)
                        if(msg.payload.clientType == CLIENT_TYPE_ROUTERSERVER) { // Match internal services
                            // check accesstoken against INTERNAL_SERVICE_TOKEN env
                            if(msg.payload.accessToken != Environment.get("INTERNAL_SERVICE_TOKEN")!) {
                                await sendWSMessage(ws, ACTION_RESULT, ResultPayload(forAction: ACTION_DEVICE_HELLO, status: false, data: ErrorPayload(msg: "Invalid Access Token")), id)
                                return
                            } else {
                                routerServiceWS = ws;
                                uuid = CLIENT_TYPE_ROUTERSERVER;
                                await sendWSMessage(ws, ACTION_RESULT, ResultPayload(forAction: ACTION_DEVICE_HELLO, status: true, data: true), id)
                            }
                        } else {
                            guard let org = try await getOrgByDeviceToken(db, msg.payload.accessToken) else {
                                // invalid access token
                                await sendWSMessage(ws, ACTION_RESULT, ResultPayload(forAction: ACTION_DEVICE_HELLO, status: false, data: ErrorPayload(msg: "Invalid Access Token")), id)
                                return
                            }
                            states.updateValue(ClientState(uuid: msg.payload.uuid, ws: ws, name: msg.payload.name ?? "Unnamed Device", type: msg.payload.clientType, orgUUID: org.uuid), forKey: msg.payload.uuid)
                            uuid = msg.payload.uuid;
                            await sendWSMessage(ws, ACTION_RESULT, ResultPayload(forAction: ACTION_DEVICE_HELLO, status: true, data: org), id)
                        }
                    default:
                        // ---------- protected actions ----------
                        // (logged in)
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
                            guard let org = try await getOrganizationByUUID(db, msg.payload.uuid) else {
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
                        case ACTION_GET_ORG_DEVICES:
                            let msg: WSMessage = try JSONDecoder().decode(WSMessage<GetOrgPayload>.self, from: msgData)
                            // check if user is in the request organization
                            guard try await isUserInOrganization(db, uuid!, msg.payload.uuid) else {
                                await sendWSMessage(ws, ACTION_RESULT, ResultPayload(forAction: ACTION_GET_ORG_DEVICES, status: false, data: ErrorPayload(msg: "User is not in organization")), id)
                                return
                            }
                            // filter states by orgUUID
                            let devices = states.filter({ $0.value.orgUUID == msg.payload.uuid }).map({ $0.value })
                            // map ClientState to ClientStateCodable
                            let devicesCodable = devices.map({ ClientStateCodable(uuid: $0.uuid, name: $0.name, type: $0.type) })
                            await sendWSMessage(ws, ACTION_RESULT, ResultPayload(forAction: ACTION_GET_ORG_DEVICES, status: true, data: devicesCodable), id)
                        case ACTION_CREATE_ORG:
                            let msg: WSMessage = try JSONDecoder().decode(WSMessage<CreateOrgPayload>.self, from: msgData)
                            do{
                                try await createOrg(db, Organization(
                                    id: 0,
                                    uuid: "",
                                    name: msg.payload.name,
                                    tier: "basic",
                                    device_token: nil
                                ), uuid!)
                                await sendWSMessage(ws, ACTION_RESULT, ResultPayload(forAction: ACTION_CREATE_ORG, status: true, data: true), id)
                            } catch {
                                await sendWSMessage(ws, ACTION_RESULT, ResultPayload(forAction: ACTION_CREATE_ORG, status: false, data: ErrorPayload(msg: error.localizedDescription)), id)
                                return
                            }
                        // router
                        case ACTION_ROUTER_CLIENT_REGISTER_PORT:
                            let msg: WSMessage = try JSONDecoder().decode(WSMessage<RouterClientRegisterPortPayload>.self, from: msgData)
                            guard let routerServer = routerServiceWS else {
                                await sendWSMessage(ws, ACTION_RESULT, ResultPayload(forAction: ACTION_ROUTER_CLIENT_REGISTER_PORT, status: false, data: ErrorPayload(msg: "Failed to register port. Try again later?")), id)
                                return
                            }
                            var publicPort = Int.random(in: 1025...65534);
                            while(true) {
                                publicPort = Int.random(in: 1025...65534);
                                if routerPortMappings[publicPort] == nil {
                                    break;
                                }
                            }
                            let payload = RouterClientRegisterPortPayload(
                                port: msg.payload.port,
                                proto: msg.payload.proto,
                                name: msg.payload.name,
                                publicPort: publicPort,
                                clientUUID: uuid!
                            );
                            routerPortMappings.updateValue(payload, forKey: publicPort)
                            await sendWSMessage(routerServer, ACTION_ROUTER_CLIENT_REGISTER_PORT, payload, id)
                            await sendWSMessage(ws, ACTION_RESULT, ResultPayload(forAction: ACTION_ROUTER_CLIENT_REGISTER_PORT, status: true, data: payload), id)
                        case ACTION_ROUTER_PASS_PACKET:
                            let msg: WSMessage = try JSONDecoder().decode(WSMessage<RouterPassPacketPayload>.self, from: msgData)
                            guard let routerServer = routerServiceWS else {
                                await sendWSMessage(ws, ACTION_RESULT, ResultPayload(forAction: ACTION_ROUTER_PASS_PACKET, status: false, data: ErrorPayload(msg: "Failed to pass packet. Try again later?")), id)
                                return
                            }
                            if(uuid == CLIENT_TYPE_ROUTERSERVER) {
                                //print("from router server")
                                // packet is coming from server (from end user) to client (facing cloud clients own server).
                                guard let client = routerPortMappings[msg.payload.publicPort] else {
                                    await sendWSMessage(ws, ACTION_RESULT, ResultPayload(forAction: ACTION_ROUTER_PASS_PACKET, status: false, data: ErrorPayload(msg: "Failed to pass packet. Try again later? 2")), id)
                                    return
                                }
                                // text is the raw message from websocket
                                try? await getState(externalUUID: client.clientUUID)?.ws.send(text)
                                // result
                                //await sendWSMessage(ws, ACTION_RESULT, ResultPayload(forAction: ACTION_ROUTER_PASS_PACKET, status: true, data: true), id)
                            } else if(getState()?.type == CLIENT_TYPE_ROUTERCLIENT || getState()?.type == CLIENT_TYPE_PROLINUX) {
                                //print("from router client")
                                // send packet to routerServiceWS
                                try? await routerServer.send(text)
                                // result
                                //await sendWSMessage(ws, ACTION_RESULT, ResultPayload(forAction: ACTION_ROUTER_PASS_PACKET, status: true, data: true), id)
                            }
                        case ACTION_ROUTER_CONNECTION_DISCONNECTED:
                            let msg: WSMessage = try JSONDecoder().decode(WSMessage<RouterConnectionDisconnectedPayload>.self, from: msgData)
                            guard let routerServer = routerServiceWS else {
                                await sendWSMessage(ws, ACTION_RESULT, ResultPayload(forAction: ACTION_ROUTER_PASS_PACKET, status: false, data: ErrorPayload(msg: "Failed to pass packet. Try again later?")), id)
                                return
                            }
                            // router server (sineware) is sending to the client (user daemon) mapped by publicPort
                            if(uuid == CLIENT_TYPE_ROUTERSERVER) {
                                guard let client = routerPortMappings[msg.payload.publicPort] else {
                                    await sendWSMessage(ws, ACTION_RESULT, ResultPayload(forAction: ACTION_ROUTER_CONNECTION_DISCONNECTED, status: false, data: ErrorPayload(msg: "Failed to pass packet. Try again later?")), id)
                                    return
                                }
                                try? await getState(externalUUID: client.clientUUID)?.ws.send(text)
                            } else if(getState()?.type == CLIENT_TYPE_ROUTERCLIENT || getState()?.type == CLIENT_TYPE_PROLINUX) {
                                try? await routerServer.send(text)
                            }
                        case ACTION_EXTSERVICE_PASS_MSG:
                            let msg: WSMessage = try JSONDecoder().decode(WSMessage<ExtensionServiceWSMessageContainer>.self, from: msgData)
                            // check clientUUID exists
                            guard let client = getState(externalUUID: msg.payload.clientUUID) else {
                                await sendWSMessage(ws, ACTION_RESULT, ResultPayload(forAction: ACTION_EXTSERVICE_PASS_MSG, status: false, data: ErrorPayload(msg: "Failed to pass message. Try again later?")), id)
                                return
                            }
                            // send message to client
                            try? await client.ws.send(msg.payload.msg)


                        default:
                            // Hand off to Extension Service
                            if let extensionService = extensionServiceWS {
                                guard let uuid = uuid else {
                                    await sendWSError(ws, "Unable to handle action, no UUID!")
                                    return
                                }
                                try? await extensionService.send(String(data: (try! JSONEncoder().encode(ExtensionServiceWSMessageContainer(clientUUID: uuid, msg: text))), encoding: .utf8)!)
                            } else {
                                await sendWSError(ws, "Unable to handle action, no extension service available!")
                                return
                            }
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
            logger.info("Client disconnected! \(uuid!)")
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
func sendWSMessage<PayloadType: Codable>(_ ws: WebSocket?, _ action: String, _ payload: PayloadType, _ id: String? = nil) async {
    let msg = WSMessage<PayloadType>(id: id, action: action, payload: payload)
    try? await ws!.send(String(data: (try! JSONEncoder().encode(msg)), encoding: .utf8)!)
}
