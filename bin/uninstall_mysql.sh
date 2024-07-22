#!/bin/bash
set -e

CURRENT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )
PARENT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." >/dev/null 2>&1 && pwd )

# 加载配置文件
source $PARENT_DIR/conf/mysql.cnf
source $CURRENT_DIR/mysql.sh

# 若MySQL在运行则停止
function stop_mysql(){
    local IS_RUNNING=`ps -ef|grep mysqld|grep ${CLEAN_MYSQL_PORT}|grep defaults-file|wc -l`
    if [ ${IS_RUNNING} -eq 1 ];then
      print_info "停止MySQL..."
      systemctl stop mysqld${CLEAN_MYSQL_PORT}
    fi
}

function rm_dir(){
    if [ -d ${CLEAN_DATA_DIR} ];then
        print_info "删除数据文件 ${CLEAN_DATA_DIR}"
        rm -rf ${CLEAN_DATA_DIR}
    else
        print_warning "数据文件 ${CLEAN_DATA_DIR} 不存在，请检查！！"
    fi
    # 删除软链
    if [ -L /tmp/mysql.sock ];then
        local CHK_RESULT=$(ls -l /tmp/mysql.sock |grep mysql${CLEAN_MYSQL_PORT}|wc -l)
        if [ $CHK_RESULT -gt 0 ];then
            print_info "删除软链[/tmp/mysql.sock-->mysql${CLEAN_MYSQL_PORT}]]"
            rm -f /tmp/mysql.sock
        fi
    fi

    print_info "删除环境变量文件 /etc/profile.d/mysql_set_env.sh"
    rm -f /etc/profile.d/mysql_set_env.sh
    print_info "删除systemctl启停服务 /usr/lib/systemd/system/mysqld${CLEAN_MYSQL_PORT}.service"
    rm -f /usr/lib/systemd/system/mysqld${CLEAN_MYSQL_PORT}.service
}

function del_slow_log_crontab(){
    print_info "卸载[慢日志管理]定时任务 slow_log_rotate.sh"
    $CURRENT_DIR/slow_log_rotate.sh delete
}


function main(){
    CLEAN_MYSQL_PORT=$1
    CLEAN_DATA_DIR=${2-$MYSQL_DATA_DIR/mysql$CLEAN_MYSQL_PORT}
    if [ ! $CLEAN_MYSQL_PORT ];then
        print_error "需要传入需清理的MySQL端口,如： $0 [3306]"
        exit 1
    fi
    print_info "开始卸载..."
    stop_mysql
    rm_dir
    del_slow_log_crontab
    print_info "MySQL 卸载完成."
}

main $1 $2
