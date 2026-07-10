#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
BB=/usr/bin/busybox
$BB mount -t proc proc /proc; $BB mount -t sysfs sysfs /sys
$BB mount -t devtmpfs devtmpfs /dev 2>/dev/null
$BB mount -t tmpfs tmpfs /tmp
$BB mount -t hostfs -o /home/prozak/uml-smoke none /host 2>/dev/null
R=/host/shards/checkenv-report
{
echo "== dmsetup =="; dmsetup version 2>&1 | head -3
echo "== dm targets =="; dmsetup targets 2>&1 | head -8
echo "== su fsgqa =="; su fsgqa -c 'id' 2>&1
echo "== su -s override =="; su -s /bin/bash fsgqa -c 'echo shell-ok' 2>&1
echo "== setquota =="; setquota --version 2>&1 | head -1
echo "== repquota =="; repquota --version 2>&1 | head -1
echo "== fsverity =="; fsverity --version 2>&1 | head -1
echo "== fio =="; fio --version 2>&1 | head -1
echo "== pool devices visible =="; ls /dev/ubd* 2>&1
} > $R 2>&1
sync; $BB poweroff -f
