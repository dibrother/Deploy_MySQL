#!/bin/bash
set -e

: <<COMMENT
# 单独使用此脚本：
#  1.配置下列参数信息并将此块的注释打开
#  2.注释 下面 source conf_mysql.cnf 的行
MYSQL_DIR=/data
MYSQL_PORT=3306
INIT_PASSWORD='Test@123456'
REPL_USER='repl'
REPL_PASSWORD='Repl@123456'
COMMENT

CURRENT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )
PARENT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." >/dev/null 2>&1 && pwd )

# 加载配置文件
source $CURRENT_DIR/mysql.sh

#MYSQL_BIN_DIR=/usr/local/mysql/bin/mysql
#SOCKET_DIR=$MYSQL_DIR/mysql$MYSQL_PORT/data/mysql.sock


check_params_basic(){
  if [ ! $MYSQL_PORT ] || [ ! $INIT_PASSWORD ] || [ ! $REPL_USER ] || [ ! $REPL_PASSWORD ];then
    print_error "传入指令参数不全，请检查 deploy_cnf 配置文件！"
    exit 1
  fi
}

rejoin_as_slave(){
  # 重新加入集群
  local MYSQL_STATUS=`systemctl status mysqld${MYSQL_PORT}.service |grep "active (running)"|wc -l`
  if [ $MYSQL_STATUS -gt 0 ];then
    print_info "MySQL已启动..."
    print_info "进行新旧GTID确认比对..."
    local OLD_SERVER_UUID=$($MYSQL_BIN_DIR/mysql -uroot -p"${INIT_PASSWORD}" -S $SOCKET_DIR -e "select @@server_uuid uid\G"|grep uid:|awk '{print $2}')
    local OLD_GTIDS=$($MYSQL_BIN_DIR/mysql -uroot -p"${INIT_PASSWORD}" -S $SOCKET_DIR -e "show master status;"|grep $OLD_SERVER_UUID|awk '{print $3}')
    local NEW_GTIDS=$($MYSQL_BIN_DIR/mysql -u${REPL_USER} -p"${REPL_PASSWORD}" -h${NOW_TO_SOURCE_IPADDR} -P${MYSQL_PORT}  -e "show master status;"|grep $OLD_SERVER_UUID|awk '{print $3}')
    local ARRAY_OLD_GTIDS=(${OLD_GTIDS//,\\n/ })
    local ARRAY_NEW_GTIDS=(${NEW_GTIDS//,\\n/ })
    
    # 获取并赋值新旧的GTID，如 ：babf7bad-5071-11ee-a418-000c29999565:1-13
    for GTID_OLD in ${ARRAY_OLD_GTIDS[@]}
    do
      local DTL_GTID=`echo ${GTID_OLD%:*}`
      if [[ $OLD_SERVER_UUID = $DTL_GTID ]];then
        local OLD_GTID=$GTID_OLD
      fi
    done
    for GTID_NEW in ${ARRAY_NEW_GTIDS[@]}
    do
      local DTL_GTID=`echo ${GTID_NEW%:*}`
      if [[ $OLD_SERVER_UUID = $DTL_GTID ]];then
        local NEW_GTID=$GTID_NEW
      fi
    done
    
    # 对进行旧GTID进行比对
    if [[ ${OLD_GTID} < ${NEW_GTID} ]] || [[ ${OLD_GTID} = ${NEW_GTID} ]];then
      print_info "配置主从关系，主为：${NOW_TO_SOURCE_IPADDR}"
      cd $SCRIPT_DIR
      join_tobe_slave $NOW_TO_SOURCE_IPADDR
      print_info "配置从库参数..."
      set_repl_params
      print_info "已成功加入当前主."
    else
      print_error "当前节点GTID值比主节点的大，不能作为从库加入，请手动检查..."
    fi
  else
    print_error "MySQL未启动，请先启动MySQL服务..."
    exit 1
  fi
}

# 从加入主,不会更改已有GTID
function join_tobe_slave(){
  local MASTER_HOST=$1
  print_info "建立主从关系，目标主库地址为：$MASTER_HOST"
  local REPLICA_STATUS=''
  local CHK_VERSION=$($MYSQL_BIN_DIR/mysql -uroot -p"${INIT_PASSWORD}" -S ${SOCKET_DIR} -Ne "select version()" 2>/dev/null) 
  if [[ $CHK_VERSION > "8.0.25" ]];then
      $MYSQL_BIN_DIR/mysql -uroot -p"${INIT_PASSWORD}" -S ${SOCKET_DIR} -e "STOP REPLICA;CHANGE REPLICATION SOURCE TO SOURCE_HOST = '${MASTER_HOST}',SOURCE_PORT = ${MYSQL_PORT},SOURCE_USER = '${REPL_USER}',SOURCE_PASSWORD = '${REPL_PASSWORD}',SOURCE_AUTO_POSITION = 1,MASTER_SSL = 1;START REPLICA;" 2>/dev/null
      REPLICA_STATUS=$($MYSQL_BIN_DIR/mysql -uroot -p"${INIT_PASSWORD}" -S ${SOCKET_DIR} -e"show replica status\G" 2>/dev/null|grep -E "Replica_IO_Running:|Replica_SQL_Running:"|grep "Yes"|wc -l) 
  else
      $MYSQL_BIN_DIR/mysql -uroot -p"${INIT_PASSWORD}" -S ${SOCKET_DIR} -e "STOP SLAVE;CHANGE MASTER TO MASTER_HOST = '$MASTER_HOST',MASTER_PORT = $MYSQL_PORT,MASTER_USER = '$REPL_USER',MASTER_PASSWORD = '${REPL_PASSWORD}',MASTER_AUTO_POSITION = 1;START SLAVE;" 2>/dev/null
      REPLICA_STATUS=$($MYSQL_BIN_DIR/mysql -uroot -p"${INIT_PASSWORD}" -S ${SOCKET_DIR} -e"show slave status\G" 2>/dev/null|grep -E "Slave_IO_Running:|Slave_SQL_Running:"|grep "Yes"|wc -l) 
  fi

  if [ $REPLICA_STATUS -eq 2 ];then
    print_info "主从关系建立成功..."
  else
    print_error "主从关系建立失败,请检查!"
    exit 1
  fi
}

# 设置复制相关的参数
function set_repl_params(){
  local CHK_VERSION=$($MYSQL_BIN_DIR/mysql -uroot -p"${INIT_PASSWORD}" -S ${SOCKET_DIR} -Ne "select version()" 2>/dev/null) 
  if [[ $CHK_VERSION > "8.0.25" ]];then
    $MYSQL_BIN_DIR/mysql -uroot -p"${INIT_PASSWORD}" -S ${SOCKET_DIR} -e "set global read_only=1;set global super_read_only=1;" 2>/dev/null
    $MYSQL_BIN_DIR/mysql -uroot -p"${INIT_PASSWORD}" -S ${SOCKET_DIR} -e "set global rpl_semi_sync_source_enabled=0;set global rpl_semi_sync_replica_enabled=1;" 2>/dev/null
  else
    $MYSQL_BIN_DIR/mysql -uroot -p"${INIT_PASSWORD}" -S ${SOCKET_DIR} -e "set global read_only=1;set global super_read_only=1;" 2>/dev/null
    $MYSQL_BIN_DIR/mysql -uroot -p"${INIT_PASSWORD}" -S ${SOCKET_DIR} -e "set global rpl_semi_sync_master_enabled=0;set global rpl_semi_sync_slave_enabled=1;" 2>/dev/null
  fi
  print_info "主从相关参数设置完成."
}

if [ $1 ];then
  NOW_TO_SOURCE_IPADDR=$1
  check_params_basic 
  rejoin_as_slave
  set_repl_params
else
  printf "Usage: bash rejoin_as_slave.sh 主节点IP\n       如:./rejoin_as_slave.sh 192.168.66.161\n"
  exit
fi
