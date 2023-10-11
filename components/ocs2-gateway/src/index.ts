import { WebSocketServer, WebSocket } from 'ws';
console.log("Starting OCS2 Gateway...");
const wss = new WebSocketServer({ port: 8088 });

interface v1WSMessage {
    action: string;
    payload: any;
    id?: string;
}
interface v2WSMessage {
    a: number;
    p: any;
    i?: string;
}

// action string to number mapping
const actionMap = {
    "hello": 0,
    "device-hello": 1,
    "update-selected-org": 2,
    "ping": 3,
    "pong": 4,
    "debug": 5,
    "register": 6,
    "get-self": 7,
    "get-orgs": 8,
    "create-org": 9,
    "get-org-websites": 10,
    "create-org-website": 11,
    "result": 12,
    "router-client-register-port": 13,
    "router-client-unregister-port": 14,
    "router-pass-packet": 15,
    "router-connection-disconnected": 16,
    "get-org-routers": 17,
    "get-org-router-ports": 18,
    "get-org-devices": 19,
    "device-login": 20,
    "device-stream-terminal": 21,
    "device-exec": 22,

}

function v2MessageTransformer(msg: any, from: "client" | "upstream"): string {
    // transforms the message to v2 format if it comes from upstream, and convert it back to v1 if it comes from the client
    if(from === "upstream") {
        // from upstream
        const v2msg: v2WSMessage = {
            a: actionMap[msg.action as keyof typeof actionMap],
            p: msg.payload,
        }
        return JSON.stringify(v2msg);
    } else {
        // from client
        const v1msg: v1WSMessage = {
            action: Object.keys(actionMap).find(key => actionMap[key as keyof typeof actionMap] === msg.a)!,
            payload: msg.p,
        }
        return JSON.stringify(v1msg);
    }
}

wss.on('connection', function connection(ws) {
    let v2APIEnabled = false;
    const upstream = new WebSocket(`ws://ocs2:8080/gateway`);

    upstream.on('error', console.error);

    upstream.on('open', function open() {});

    upstream.on('message', function message(data) {
        // From Upstream
        try {
            console.log('received upstream: %s', data);
            const msg: v1WSMessage = JSON.parse(data.toString());

            if(v2APIEnabled) ws.send(v2MessageTransformer(msg, "upstream"));
            else ws.send(data);
        } catch(e) {
            console.error(e);
            ws.close();
            upstream.close();
        }
        
    });

    ws.on('error', console.error);

    ws.on('message', function message(data) {
        try {
            // From client
            console.log('received: %s', data);
            const msg: v1WSMessage & v2WSMessage = JSON.parse(data.toString());
            
            if(msg.action === "switch-v2") {
                v2APIEnabled = true;
                ws.send(JSON.stringify({ action: "result", payload: { 
                    forAction: "switch-v2",
                    status: true,
                    data: ""
                }}));
                return;
            }

            if(v2APIEnabled) upstream.send(v2MessageTransformer(msg, "client"));
            else upstream.send(JSON.stringify(msg));
        } catch(e) {
            console.error(e);
            upstream.close();
            ws.close();
        }
    });
});

console.log("OCS2 Gateway started on port 8088");
