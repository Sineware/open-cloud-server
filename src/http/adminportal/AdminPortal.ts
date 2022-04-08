import express from "express";
import {server} from "../../index";

export default function registerAdminPortalRoutes(app: express.Express) {
    app.get('/', function(req, res) {
        res.render('pages/index', {
            gatewayClientCount: server.gateways.length,
            memUsage: process.memoryUsage()
        });
    });
}