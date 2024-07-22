#!/bin/bash
# 用于循环写入测试数据
# 会创建一个 db 名称d的数据库,并创一张 tb  表,循环写入数据

host='10.10.2.111'
user='super_admin'
passwd='123456'
port='3310'
db=yqtest
tb=t1


CURRENT_DIR=$(cd `dirname $0`; pwd)
PARENT_DIR=$(dirname "$(pwd)")

if [ "$host" = '' ];then
   source $PARENT_DIR/install/conf_mysql.cnf
   host=${VIP}
   user=$SUPER_USER
   passwd="$SUPER_PASSWORD"
   port=$MYSQL_PORT
fi

mysql -u$user -h$host -p${passwd} -P$port -e "create database if not exists $db;"
mysql -u$user -h$host -p${passwd} -P$port yqtest -e "create table if not exists $tb(id int auto_increment primary key,vtime varchar(30));"

for i in $(seq 1 1000000);
do
  echo $(date +'%Y-%m-%d %H:%M:%S')
  mysql -u$user -h$host -p${passwd} -P$port -e "insert into $db.$tb(vtime) values(now());"
done;
