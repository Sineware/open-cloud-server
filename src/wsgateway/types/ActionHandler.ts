import {validate, ValidationError} from "class-validator";
import WSMessage from "./WSMessage";
import WSGateway from "../WSGateway";
import {Logger} from "tslog";

export default abstract class ActionHandler<PayloadType> {
    gateway: WSGateway;
    log: Logger = new Logger();
    constructor(gateway: WSGateway) {
        this.gateway = gateway;
    }

    /**
     * @throws {ValidationError}
     */
    async validate(payloadClass: any, payloadObj: PayloadType): Promise<PayloadType>  {
        const payload = Object.assign(new payloadClass, payloadObj);
        let errors = await validate(payload);
        this.log.debug(errors);
        if(errors.length > 0) {
            throw errors;
        }
        return payload;
    }

    sendError(msg: string, details: object) {
        this.gateway.send("error", {
            msg,
            details
        });
    }

    abstract handle(payload: PayloadType): Promise<void> | Promise<WSMessage>
}