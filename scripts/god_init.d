#!/bin/bash

#
# God init.d (startup) script 
#
# save this file as /etc/init.d/god
# make it executable:
#    chmod +x /etc/init.d/god
# Tell the os to run the script at startup:
#    sudo /usr/sbin/update-rc.d -f god defaults
#
# Also consider adding this line (kills god weekly) to your crontab (sudo crontab -e):
#
#    0 1 * * 0 god quit; sleep 1; killall god; sleep 1; killall -9 god; sleep 1; god -c /etc/god.conf
# 

RETVAL=0
god_conf="/etc/god.conf"
god_pid_file="/var/run/god.pid"
god_log_file="/var/log/god.log"
case "$1" in
  start)
    god -c "$god_conf" -P "$god_pid_file" -l "$god_log_file"
    RETVAL=$?
    echo "God started"
    ;;
  stop)
    kill `cat $god_pid_file`
    RETVAL=$?
    echo "God stopped"
    ;;
  restart)
    kill `cat $god_pid_file`
    god -c "$god_conf" -P "$god_pid_file" -l "$god_log_file"
    RETVAL=$?
    echo "God restarted"
    ;;
  status)
    RETVAL=$?
    ;;
  *)
    echo "Usage: god {start|stop|restart|status}"
    exit 1
    ;;
esac

exit $RETVAL