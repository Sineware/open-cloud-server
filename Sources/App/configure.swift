import Vapor
import PostgresNIO

// configures your application
public func configure(_ app: Application) throws {
    // CORS
    let corsConfiguration = CORSMiddleware.Configuration(
        allowedOrigin: .all,
        allowedMethods: [.GET, .POST, .PUT, .OPTIONS, .DELETE, .PATCH],
        allowedHeaders: [.accept, .authorization, .contentType, .origin, .xRequestedWith, .userAgent, .accessControlAllowOrigin]
    )
    let cors = CORSMiddleware(configuration: corsConfiguration)
    // cors middleware should come before default error middleware using `at: .beginning`
    app.middleware.use(cors, at: .beginning)
    
    app.middleware.use(CloudPagesMiddleware())
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory, defaultFile: "index.html"))

    app.http.server.configuration.serverName = "sineware-open-cloud-server"

    print(Environment.get("PG_HOST") as Any)
    if(Environment.get("PG_HOST") == nil) {
        print("PG Environment Variables not set!")
        exit(-1)
    }

    // register routes
    try routes(app)
}
