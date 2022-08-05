#!/usr/bin/env bash
USER=swadmin
HOST=192.168.11.88
DIR=/storagepool/ocs/src/

#swift build -c release --static-swift-stdlib
rsync -avz --delete --exclude ".build" . ${USER}@${HOST}:${DIR}

exit 0