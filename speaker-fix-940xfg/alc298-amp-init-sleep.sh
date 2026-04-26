#!/bin/bash
#
# system-sleep hook: re-fire the ALC298 amp init after resume from suspend.
# Suspend power-cycles the codec; our COEF writes are lost across S3, so we
# need to re-apply them on wake. Installed to /lib/systemd/system-sleep/.
#
# systemd calls this with two arguments:
#   $1 = pre  | post
#   $2 = suspend | hibernate | hybrid-sleep | suspend-then-hibernate
#

case "$1" in
    post)
        case "$2" in
            suspend|hibernate|hybrid-sleep|suspend-then-hibernate)
                /usr/local/sbin/alc298-amp-init.sh || true
                ;;
        esac
        ;;
esac
