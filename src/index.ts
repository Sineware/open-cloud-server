// Vendor
import "reflect-metadata"
import { Logger } from "tslog";
import {WebSocket, WebSocketServer} from 'ws';
import * as http from "http";
import express from "express";
import { parse } from 'url';
import helmet from "helmet";
import net from "net";
import { Long, serialize, deserialize } from 'bson';


// Internal
import WSGateway from "./wsgateway/WSGateway";
import registerAdminPortalRoutes from "./http/adminportal/AdminPortal";
import ConnectionType from "./wsgateway/types/ConnectionType";
import CloudEdgeNode from "./bitp/CloudEdgeNode";

console.log("Starting Sineware Open Cloud Server 2...");

const log: Logger = new Logger();
export class CloudServer {
    // Vendor Servers
    nodeHTTPServer?: http.Server;
    expressServer?: express.Express;
    wsServer?: WebSocketServer;
    tcpServer?: net.Server;

    // Internal
    gateways: WSGateway[] = [];
    edges: CloudEdgeNode[] = [];

    async start() {
        try {
            log.info("Beginning startup... 🚀");

            log.info("Starting: Express HTTP Server");
            this.expressServer = express();

            // Middleware
            this.expressServer.set('view engine', 'ejs');
            this.expressServer.use(helmet());
            this.expressServer.use(express.static('public'));

            // Routes
            registerAdminPortalRoutes(this.expressServer);

            this.nodeHTTPServer = http.createServer(this.expressServer);
            this.nodeHTTPServer.listen(3001, () => log.info("HTTP Server Callback Success"));
            log.info("Started: Express HTTP server on 3001");

            log.info("Starting: Websocket Gateway Server");
            this.wsServer = new WebSocketServer({ noServer: true });
            this.nodeHTTPServer.on('upgrade', (request, socket, head) => {
                const { pathname } = parse(request.url!);
                if (pathname === '/api/v1/gateway') {
                    this.wsServer!.handleUpgrade(request, socket, head, (ws) => {
                        const ip = request.headers['x-forwarded-for'] || request.socket.remoteAddress || null;
                        log.info("New websocket connect from: " + ip);
                        this.gateways.push(new WSGateway(this, ws, ConnectionType.LOCAL));
                    });
                } else {
                    socket.destroy();
                }
            });
            log.info("Started: Websocket Gateway Server");

            log.info("Starting: BITp Server");
            // Sineware Cloud - Binary Intracloud Transport Protocol
            this.tcpServer = new net.Server();

            this.tcpServer.listen(3002, function() {
                log.info(`BITp TCP Server Callback Success on ${3002}`);
            });

            this.tcpServer.on("connection", (socket) => {
                log.debug("New Cloud Edge node connection over BITp from " + socket.remoteAddress);
                this.edges.push(new CloudEdgeNode(this, socket));
            });
            log.info("Started: BITp Server");
        } catch(e) {
            log.error("An error occurred starting Sineware OCS 2!");
            log.error(e);
            process.exit(2);
        }

    }
}

process.on('unhandledRejection', (e) => {
    log.error("An unexpected fatal error occurred!");
    log.error(e);
    process.exit(1);
});

export const server = new CloudServer();
server.start().then(() => {
    log.info("Initial startup complete!");
})
