

yum install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm
percona-release enable-only tools release
yum install -y percona-xtrabackup-80

wget https://repo.percona.com/apt/percona-release_latest.$(lsb_release -sc)_all.deb
dpkg -i percona-release_latest.$(lsb_release -sc)_all.deb
percona-release enable-only tools release
apt update
apt install percona-xtrabackup-83