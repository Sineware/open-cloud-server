import {Logger} from "tslog";
import {RawData, WebSocket} from "ws";
import WSMessage from "./types/WSMessage";
import {validate} from "class-validator";
import ActionHandler from "./types/ActionHandler";
import Queue from "queue";
import PingHandler from "./actions/PingHandler";
import ClientType from "./types/ClientType";
import {CloudServer} from "../index";
import Actions from "./types/Actions";
import ConnectionType from "./types/ConnectionType";
import net from "net";

const log: Logger = new Logger();

export default class WSGateway {
    socket: WebSocket | net.Socket
    server: CloudServer
    q: Queue = new Queue({concurrency: 1, autostart: true});
    actionMap: Map<string, ActionHandler<any>> = new Map<string, ActionHandler<any>>();

    // Client
    type: ClientType = ClientType.UNKNOWN;
    connectionType: ConnectionType;

    constructor(server: CloudServer, socket: WebSocket | net.Socket, type: ConnectionType) {
        this.socket = socket
        this.server = server;
        this.connectionType = type;

        this.registerWSActions();

        if(type === ConnectionType.LOCAL) {
            this.socket.on("message", (r) => this.handleMessage(r));
            this.socket.on("close", () => {
                log.info("Client disconnected, type " + this.type);
                this.q.end();
                this.server.gateways.splice(this.server.gateways.indexOf(this), 1);
            });
        } else if(type === ConnectionType.REMOTE) {
            // do stuff
        }

        this.q.on("success", (res: WSMessage | undefined) => {
            if(res !== undefined) {
                // Some Actions return an answer
                this.send(res.action!, res.payload!);
            }
        });
        this.q.on("error", (err) => {
            this.send("error", {
                msg: "An error occurred processing the action request!",
                details: err
            });
        });
        // todo timeout
    }

    registerWSActions() {
        log.info("Registering Websocket Actions...");
        this.actionMap.set(Actions.PING, new PingHandler(this));
    }

    send(action: string, payload: object) {
        if(this.connectionType === ConnectionType.LOCAL) {
            (this.socket as WebSocket).send(JSON.stringify({ action: action, payload: payload }));
        } else {
            // todo do stuff
        }
    }

    async handleMessage(rawMsg: RawData) {
        try {
            log.debug(JSON.parse(rawMsg.toString()));
            // todo a or action
            const msg: WSMessage = Object.assign(new WSMessage, JSON.parse(rawMsg.toString()))
            let errors = await validate(msg);
            if (errors.length === 0) {
                let actionHandler = this.actionMap.get(msg.action!);
                if(actionHandler === undefined) {
                    this.send("error", {
                        msg: "Invalid Action type",
                        details: null
                    });
                } else {
                    this.q.push(async () => await actionHandler!.handle(msg.payload!));
                }
            } else {
                console.debug(errors);
                this.send("error", {
                    msg: "Invalid WSMessage scheme",
                    details: errors
                })
            }
        } catch (e) {
            this.send("error", {
                msg: "Invalid JSON",
                details: null
            });
        }
    }
}