import Vapor

class CloudPagesMiddleware: AsyncMiddleware {
    func respond(to req: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let db = try await connectDatabase()
        let domain = req.headers.first(name: "Host") ?? "Unknown Host"
        print(NSDate().description)
        print("Host: \(domain)")
        guard let website = try await getWebsiteByDomain(db, domain) else {
            try await db.close()
            return try await next.respond(to: req)
        }
        try await db.close()
        print("Serving Cloud Pages for Website: \(website.name)")
        print(website as Any)

        req.headers.add(name: "X-Powered-By", value: "Sineware Cloud Pages")

        // make a copy of the percent-decoded path
        guard var path = req.url.path.removingPercentEncoding else {
            throw Abort(.badRequest)
        }
        // path must be relative.
        path = path.removeLeadingSlashes()
        // protect against relative paths
        guard !path.contains("../") else {
            throw Abort(.forbidden)
        }

        path = req.application.directory.workingDirectory + "storage/" + website.uuid.lowercased() + "/" + path

        // check if path exists and whether it is a directory, serve index.html
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            throw Abort(.notFound)
        } 
        if isDir.boolValue {
            path = path.addTrailingSlash() + "index.html"
            guard FileManager.default.fileExists(atPath: path) else {
                // todo maybe allow a directory listing option.
                throw Abort(.notFound)
            }
        }

        print(path)
        let res = req.fileio.streamFile(at: path)
        return res
    }
}

// from FileMiddleware.swift:
fileprivate extension String {
    /// Determines if input path is absolute based on a leading slash
    func isAbsolute() -> Bool {
        return self.hasPrefix("/")
    }

    /// Makes a path relative by removing all leading slashes
    func removeLeadingSlashes() -> String {
        var newPath = self
        while newPath.hasPrefix("/") {
            newPath.removeFirst()
        }
        return newPath
    }

    /// Adds a trailing slash to the path if one is not already present
    func addTrailingSlash() -> String {
        var newPath = self
        if !newPath.hasSuffix("/") {
            newPath += "/"
        }
        return newPath
    }
}
