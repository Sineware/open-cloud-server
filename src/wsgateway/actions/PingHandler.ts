import ActionHandler from "../types/ActionHandler";
import WSMessage from "../types/WSMessage";
import Actions from "../types/Actions";

class PingPayload {
}

export default class PingHandler extends ActionHandler<PingPayload> {
    async handle(payloadObj: PingPayload) {
        const payload = await this.validate(PingPayload, payloadObj);
        return new WSMessage(Actions.PONG, {});
    }
}