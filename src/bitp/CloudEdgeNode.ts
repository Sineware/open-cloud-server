import {CloudServer} from "../index";
import {Logger} from "tslog";
import net from "net";
import { Long, serialize, deserialize } from 'bson';

const log: Logger = new Logger();
export default class CloudEdgeNode {
    server: CloudServer;
    socket: net.Socket;
    constructor(server: CloudServer, socket: net.Socket) {
        this.server = server;
        this.socket = socket;
        this.socket.on("data", (data) => {
            log.debug("BITp Received: " + data);
            try {
                log.debug(deserialize(data));
            } catch (e) {
                log.error("Failed to deserialized BSON message!");
            }
        });
        this.socket.on("close", () => {
           log.info("Edge node disconnected!");
           this.server.edges.splice(this.server.edges.indexOf(this), 1);
        });
    }

    send() {

    }
}