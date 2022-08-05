import App
import Vapor

print("Starting Sineware Open Cloud Server 2...")
var env = try Environment.detect()
try LoggingSystem.bootstrap(from: &env)
let app = Application(env)
defer {
    print("Shutting down...")
    app.shutdown()
    closeDatabaseEventLoop()
}

try configure(app)
try app.run()