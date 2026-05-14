Cron schedule 0 12 * * *
launch commands:
crontab -e
1 12 * * * /home/user/test_svace.sh >> /home/user/test-svace/svace_check.log 2>&1
crontab -l
