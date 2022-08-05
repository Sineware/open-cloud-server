import PostgresNIO
import NIOPosix
import Logging
import Vapor

let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 4)
let logger = Logger(label: "postgres-logger")
public func connectDatabase() async throws -> PostgresConnection  {
    let config = PostgresConnection.Configuration(
            connection: .init(
                    host: Environment.get("PG_HOST")!,
                    port: Int(Environment.get("PG_PORT")!)!
            ),
            authentication: .init(
                    username: Environment.get("PG_USER")!,
                    database: Environment.get("PG_DB")!,
                    password: Environment.get("PG_PASS")!
            ),
            tls: .disable
    )

    let connection = try await PostgresConnection.connect(
            on: eventLoopGroup.next(),
            configuration: config,
            id: 1,
            logger: logger
    )
    /*let rows = try await connection.query("SELECT version()", logger: logger)
    print(rows)
    for try await row in rows {
        // do something with the row
        print(row)
    }*/

    return connection
}

public func closeDatabaseEventLoop() {
    do {
        try eventLoopGroup.syncShutdownGracefully()
    } catch {
        print("Failed to shutdown DB EventLoopGroup: \(error)")
    }
}

/* Queries */
public func getDBVersion(_ db: PostgresConnection) async throws -> String {
    let rows = try await db.query("SELECT version()", logger: logger)
    for try await row in rows {
        return try row.makeRandomAccess()["version"].decode((String).self, context: .default)
    }
    return "sad"
}

public func returnUserRowsAsArray(_ rows: PostgresRowSequence) async throws -> [User] {
    var users: [User] = []
    for try await row in rows {
        let randomRow = row.makeRandomAccess()
        let user = User(
                uuid: try randomRow["uuid"].decode((String).self, context: .default),
                email: try randomRow["email"].decode((String).self, context: .default),
                username: try randomRow["username"].decode((String).self, context: .default),
                fullname: try randomRow["fullname"].decode((String).self, context: .default),
                passhash: try randomRow["passhash"].decode((String).self, context: .default),
                accesstoken: try randomRow["accesstoken"].decode((String).self, context: .default),
                lastip: try? randomRow["lastip"].decode((String).self, context: .default),
                id: try randomRow["id"].decode((Int).self, context: .default),
                phone: try? randomRow["phone"].decode((String).self, context: .default),
                organizations: nil
        )
        users.append(user)
        print(user)
    }
    return users
}
public func returnOrganizationRowsAsArray(_ rows: PostgresRowSequence) async throws -> [Organization] {
    var organizations: [Organization] = []
    for try await row in rows {
        let randomRow = row.makeRandomAccess()
        let organization = Organization(
                id: try randomRow["id"].decode((Int).self, context: .default),
                uuid: try randomRow["uuid"].decode((String).self, context: .default),
                name: try randomRow["name"].decode((String).self, context: .default),
                tier: try randomRow["tier"].decode((String).self, context: .default)
        )
        organizations.append(organization)
        print(organization)
    }
    return organizations
}
public func returnWebsiteRowsAsArray(_ rows: PostgresRowSequence) async throws -> [Website] {
    var websites: [Website] = []
    for try await row in rows {
        let randomRow = row.makeRandomAccess()
        let website = Website(
                id: try randomRow["id"].decode((Int).self, context: .default),
                uuid: try randomRow["uuid"].decode((String).self, context: .default),
                organization_id: try randomRow["organization_id"].decode((Int).self, context: .default),
                domain: try randomRow["domain"].decode((String).self, context: .default),
                type: try randomRow["type"].decode((String).self, context: .default),
                name: try randomRow["name"].decode((String).self, context: .default)
        )
        websites.append(website)
        //print(website)
    }
    return websites
}

/// Register a new user into the database.
public func registerUser(_ db: PostgresConnection, _ p: RegisterPayload) async throws {
    let uuid = UUID().uuidString
    print(uuid)

    let passhash = try Bcrypt.hash(p.password)
    try await db.query("""
                       INSERT INTO users (uuid, email, username, fullname, passhash, phone) VALUES (uuid(\(uuid)), \(p.email), \(p.username), \(p.fullname), \(passhash), \(p.phone))
                       """, logger: logger)
}

// Logs in the user using username/password authentication. Returns a token if successful, otherwise nil.
public func loginUser(_ db: PostgresConnection, _ email: String, _ password: String) async throws -> String? {
    let rows = try await db.query("""
                                  SELECT * FROM users WHERE email=\(email) OR username=\(email)
                                  """, logger: logger)
    let user = try await returnUserRowsAsArray(rows).first
    if user == nil {
        return nil
    } else {
        let user = user!
        if try Bcrypt.verify(password, created: user.passhash) {
            return user.accesstoken
        } else {
            return nil
        }
    }
}

/// Returns a User for the corresponding AccessToken, or nil if none exists. Does not include Organizations
public func getUserByAccessToken(_ db: PostgresConnection, _ accessToken: String) async throws -> User? {
    let rows = try await db.query("""
                                  SELECT * FROM users WHERE accesstoken=\(accessToken)
                                  """, logger: logger)
    return try await returnUserRowsAsArray(rows).first
}
/// Returns a User for the corresponding UUID, or nil if none exists. Includes Organizations.
public func getUserByUUID(_ db: PostgresConnection, _ uuid: String) async throws -> User? {
    let rows = try await db.query("""
                                  SELECT * FROM users WHERE uuid=uuid(\(uuid))
                                  """, logger: logger)
    guard var user = try await returnUserRowsAsArray(rows).first else {
        return nil
    }
    user.organizations = try await getUserOrganizations(db, user.uuid)
    return user
}
public func getUserOrganizations(_ db: PostgresConnection, _ uuid: String) async throws -> [Organization] {
    let rows = try await db.query("""
                                  SELECT * FROM organizations WHERE id IN (SELECT organization_id FROM users_organizations WHERE user_id=(SELECT id FROM users WHERE uuid=uuid(\(uuid))))
                                  """, logger: logger)
    return try await returnOrganizationRowsAsArray(rows)
}
public func getOrganizationByUUID(_ db: PostgresConnection, _ uuid: String) async throws -> Organization? {
    let rows = try await db.query("""
                                  SELECT * FROM organizations WHERE uuid=uuid(\(uuid))
                                  """, logger: logger)
    return try await returnOrganizationRowsAsArray(rows).first
}
public func isUserInOrganization(_ db: PostgresConnection, _ userUUID: String, _ organizationUUID: String) async throws -> Bool {
    // this query was ~graciously~ provided by espidev
    let rows = try await db.query("""
                                    SELECT *
                                    FROM users_organizations
                                    INNER JOIN users ON user_id=users.id
                                    INNER JOIN organizations ON organization_id=organizations.id
                                    WHERE users.uuid = uuid(\(userUUID)) AND organizations.uuid = uuid(\(organizationUUID));
                                  """, logger: logger)
    return try await rows.collect().count > 0
}

// Website
public func getWebsiteByUUID(_ db: PostgresConnection, _ uuid: String) async throws -> Website? {
    let rows = try await db.query("""
                                  SELECT * FROM sites WHERE uuid = uuid(\(uuid))
                                  """, logger: logger)
    return try await returnWebsiteRowsAsArray(rows).first
}
// return all websites for an organization uuid
public func getOrganizationWebsites(_ db: PostgresConnection, _ organizationUUID: String) async throws -> [Website] {
    let rows = try await db.query("""
                                  SELECT * FROM sites WHERE organization_id=(SELECT id FROM organizations WHERE uuid = uuid(\(organizationUUID)))
                                  """, logger: logger)
    return try await returnWebsiteRowsAsArray(rows)
}
public func getWebsiteByDomain(_ db: PostgresConnection, _ domain: String) async throws -> Website? {
    let rows = try await db.query("""
                                  SELECT * FROM sites WHERE domain = \(domain)
                                  """, logger: logger)
    return try await returnWebsiteRowsAsArray(rows).first
}

// ~~~ Update Server ~~~
func returnUpdateRowsAsArray(_ rows: PostgresRowSequence) async throws -> [Update] {
    var arr = [Update]()
    for try await row in rows {
        let randomRow = row.makeRandomAccess()
        let update = Update(
                id: try randomRow["id"].decode((Int).self, context: .default),
                uuid: try randomRow["uuid"].decode((String).self, context: .default),
                product: try randomRow["product"].decode((String).self, context: .default),
                variant: try randomRow["variant"].decode((String).self, context: .default),
                channel: try randomRow["channel"].decode((String).self, context: .default),
                buildnum: try randomRow["buildnum"].decode((Int).self, context: .default),
                buildstring: try randomRow["buildstring"].decode((String).self, context: .default),
                isreleased: try randomRow["isreleased"].decode((Bool).self, context: .default)
        )
        arr.append(update)
    }
    return arr
}

/// Returns all Updates from the database.
public func getAllUpdates(_ db: PostgresConnection) async throws -> [Update] {
    let rows = try await db.query("""
                       SELECT * FROM updates
                       """, logger: logger)
    return try await returnUpdateRowsAsArray(rows)
}

/// Returns a single Update entry for the corresponding product, variant, and channel.
public func getSingleUpdate(_ db: PostgresConnection, _ product: String, _ variant: String, _ channel: String) async throws -> Update? {
    let rows = try await db.query("""
                       SELECT * FROM updates WHERE product=\(product) AND variant=\(variant) AND channel=\(channel)
                       """, logger: logger)
    return try await returnUpdateRowsAsArray(rows).first
}

/// Returns a single Update entry for the corresponding UUID.
public func getSingleUpdatebyUUID(_ db: PostgresConnection, _ uuid: String) async throws -> Update? {
    let rows = try await db.query("""
                        SELECT * FROM updates WHERE uuid=uuid(\(uuid))
                        """, logger: logger)
    return try await returnUpdateRowsAsArray(rows).first
}


