import {IsObject, IsString} from "class-validator";

export default class WSMessage {
    @IsString()
    action?: string

    @IsObject()
    payload?: object

    constructor(action?: string, payload?: object) {
        this.action = action;
        this.payload = payload;
    }

}