#!/bin/bash

RUN_DIR=/var/vcap/sys/run/sample-app
LOG_DIR=/var/vcap/sys/log/sample-app
PIDFILE=$RUN_DIR/sample-app.pid

mkdir -p $RUN_DIR $LOG_DIR
chown -R vcap:vcap $RUN_DIR $LOG_DIR

case $1 in
  start)
    export PORT=<%= p('port') %>
    export APP_NAME="bosh-deployed-arm64-app"
    chpst -u vcap:vcap /var/vcap/packages/sample-app/app \
      >> $LOG_DIR/sample-app.stdout.log \
      2>> $LOG_DIR/sample-app.stderr.log &
    echo $! > $PIDFILE
    ;;
  stop)
    kill -9 $(cat $PIDFILE)
    rm -f $PIDFILE
    ;;
  *)
    echo "Usage: ctl {start|stop}"
    ;;
esac
