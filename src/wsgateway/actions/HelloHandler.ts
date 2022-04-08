import ActionHandler from "../types/ActionHandler";
import {Logger} from "tslog";

const log: Logger = new Logger();

class HelloPayload {

}

export default class HelloHandler extends ActionHandler<HelloPayload> {
    async handle(payloadObj: HelloPayload) {
        const payload = await this.validate(HelloPayload, payloadObj);
        return;
    }
}