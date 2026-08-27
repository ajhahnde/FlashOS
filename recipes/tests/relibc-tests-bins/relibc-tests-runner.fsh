#!/usr/bin/fsh
cd /home/user/relibc-tests
^make run IS_REDOX=1 || exit
