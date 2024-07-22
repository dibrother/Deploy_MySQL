#!/bin/bash
set -e
set -o pipefail

CURRENT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )
PARENT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." >/dev/null 2>&1 && pwd )


# 加载配置文件
source $PARENT_DIR/conf/mysql.cnf
source $CURRENT_DIR/print_log.sh
source $CURRENT_DIR/sys.sh

# 数据目录，根据端口设置，如：/app/mysql3306/data
DATA_DIR=$MYSQL_DATA_DIR/mysql$MYSQL_PORT/data
# socket 路径，默认在data目录下
SOCKET_DIR=$DATA_DIR/mysql.sock
MYSQLX_SOCKET_DIR=$DATA_DIR/mysqlx.sock
# my.cnf 配置文件，默认放在数据目录平级，如：my3306.cnf
MYCNF_DIR=$MYSQL_DATA_DIR/mysql$MYSQL_PORT/my$MYSQL_PORT.cnf
# 默认X端口就在源端口加100
MYSQLX_PORT=`expr $MYSQL_PORT + 100`
# 默认MySQL管理端口,源默认值为 33062,这边修改为默认为 33162
MYSQL_ADMIN_PORT=`expr $MYSQL_PORT + 200`
# PID 文件
PID_FILE=$DATA_DIR/mysqld.pid
# 获取包名称
MYSQL_PKG=$(ls $PARENT_DIR/lib/*.tar*|grep "${MYSQL_VERSION}"|awk -F '/' '{print $NF}')
if [ -z "$MYSQL_PKG" ];then
    print_error "没有匹配到对应的安装包，请将对应版本的MySQL安装包放入 lib 目录下。"
    exit 1
fi
# MySQL 文件解压路径
BASE_DIR=/usr/local/$(echo ${MYSQL_PKG##*/}|awk -F ".tar" '{print $1}')
# 执行文件 bin 目录 
MYSQL_BIN_DIR=$BASE_DIR/bin


###### 高可用软件下载路径  #########


if [ $MYSQL_VERSION == "8.0" ];then
        REPLICATION_STATEMENT="replica"
        SOURCE_STATEMENT="SOURCE"
        CHANGE_STATEMENT="CHANGE REPLICATION SOURCE TO"
else
        REPLICATION_STATEMENT="slave"
        SOURCE_STATEMENT="MASTER"
        CHANGE_STATEMENT="CHANGE MASTER TO"
fi

# 执行SQL ，默认会使用配置文件中 super_admin 用户进行创建
# 执行方式 exec_sql <host> <user> <password> <port> <sql>
function do_exec_sql(){
    local host=$1
    local user=$2
    local password=$3
    local port=$4
    local sql=$5
    #print_info "执行SQL[${sql}]"
    # 使用mysql命令执行SQL，并捕获返回的状态码
    if $MYSQL_BIN_DIR/mysql -h${host} -u$user -p"${password}" -P$port -e "${sql}" > /dev/null 2>&1; then
        print_info "SQL执行成功"
    else
        print_error "SQL执行失败"
        exit 1
    fi
}

# 执行方式 exec_sql <user> <password> <socket> <sql>
function do_exec_sql_by_socket(){
    local user=$1
    local password=$2
    local socket_dir=$3
    local sql=$4
    #print_info "执行SQL[${sql}]"
    # 使用mysql命令执行SQL，并捕获返回的状态码
    if $MYSQL_BIN_DIR/mysql -u$user -p"${password}" -S $socket_dir -e "${sql}" > /dev/null 2>&1; then
        print_info "SQL执行成功"
    else
        print_error "SQL执行失败"
        exit 1
    fi
}

# 传入从库连接信息，返回正常与否，不正常会停止并报错
function check_slave_status(){
    local host=$1
    local user=$2
    local password=$3
    local port=$4
    local replica_status=$($MYSQL_BIN_DIR/mysql -h${host} -u$user -p"${password}" -P$port -e "show $REPLICATION_STATEMENT status\G" 2>/dev/null) 
    local Replica_IO_Running=$(echo "$replica_status" | grep -i "${REPLICATION_STATEMENT}_IO_Running" | awk -F: '{print $2}' | sed 's/[[:space:]]//g')
    local Replica_SQL_Running=$(echo "$replica_status" | grep -i "${REPLICATION_STATEMENT}_SQL_Running" | grep -v "State" | awk -F: '{print $2}' | sed 's/[[:space:]]//g')
    if [[ $Replica_IO_Running != 'Yes' ]] || [[ $Replica_SQL_Running != 'Yes' ]];then
        print_error "主从关系异常！\n $replica_status"
    else
        print_info "主从关系已成功建立."
    fi
}

# 检测当前实例是否为 master,输出当前状态   master-主  slave-从  slave_err-从但报错 unknown-未知状态
function check_master_or_slave(){
    local sql="SELECT 
    CASE 
        WHEN repstatus = 'MASTER' AND @@read_only = 0 THEN 'master'
				WHEN repstatus = 'ON' THEN 'slave'
				WHEN repstatus = 'BROKEN' THEN 'slave_err'
        ELSE 'unknown'
    END AS result
FROM (
    SELECT 
        COALESCE(MAX(
            CASE 
                WHEN rcs.service_state = 'ON' AND rca.service_state = 'ON' THEN 'ON'
                WHEN rcs.service_state = 'OFF' AND rca.service_state = 'OFF' THEN 'OFF'
                ELSE 'BROKEN' 
            END), 'MASTER') AS repstatus, 
        @@read_only
    FROM performance_schema.replication_connection_status rcs
    JOIN performance_schema.replication_applier_status rca
) AS subquery"
    local mysql_status=$($MYSQL_BIN_DIR/mysql -h${MYSQL_HOST} -u${SYS_MANAGER_USER} -p"${SYS_MANAGER_PWD}" -P${MYSQL_PORT} mysql -Ne  "${sql}")
    
    echo $mysql_status
}