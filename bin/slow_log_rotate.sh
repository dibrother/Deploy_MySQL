#!/bin/bash
set -e
set -o pipefail

#################################################################################################################
# author:yangqing                                                                                               #
# note:管理慢日志文件，防止过度膨胀占用空间，默认使用TABLE模式存储，保留时长为1月+1月bak                                    #
# 限制：                                                                                                         #
#     1.执行时会设置 sql_log_bin = OFF，因此不会记录下binlog,也仅在当前机器执行                                         #
#     2.MySQL 用户需要有 super 权限,可创建如下用户：                                                                 #
#       create user 'sys_manager'@'127.0.0.1' identified by 'Yq^Slow&123';                                      # 
#       grant super on *.* to  'sys_manager'@'127.0.0.1';                                                       #
#       grant all on mysql.slow_log_bak to '$SYS_MANAGER_USER'@'127.0.0.1';                                     #
#       grant all on mysql.slow_log to '$SYS_MANAGER_USER'@'127.0.0.1';                                         #
#       grant all on mysql.slow_log_new to '$SYS_MANAGER_USER'@'127.0.0.1';                                     #
#       grant select on performance_schema.replication_connection_status to '$SYS_MANAGER_USER'@'127.0.0.1';    #
#       grant select on performance_schema.replication_applier_status to '$SYS_MANAGER_USER'@'127.0.0.1';       #
#################################################################################################################

CURRENT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )
PARENT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." >/dev/null 2>&1 && pwd )

######### 无法加载配置文件，需单独使用时需要配置的参数 ##########
# MYSQL_BIN_DIR=/usr/local/mysql/bin
# MYSQL_HOST=127.0.0.1
# SYS_MANAGER_USER=sys_manager
# SYS_MANAGER_PWD=Yq^Slow&123
# MYSQL_PORT=3306
#########################################################

# 加载配置文件
source $CURRENT_DIR/mysql.sh
# 设置一些参数,如果非配置文件方式则全部注释，使用上面设置的参数
MYSQL_HOST=127.0.0.1

# 慢日志管理
function slow_log_rotate(){
    # 检测当前实例是否为 master
    local sql="SELECT 
    CASE 
        WHEN repstatus = 'MASTER' AND @@read_only = 0 THEN 'master'
        ELSE 'slave'
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
    local mysql_role=$($MYSQL_BIN_DIR/mysql -h${MYSQL_HOST} -u${SYS_MANAGER_USER} -p"${SYS_MANAGER_PWD}" -P${MYSQL_PORT} mysql -Ne  "${sql}")
    
    if [ "$mysql_role" = "master" ];then
        print_info "开始清理慢日志..."
        $MYSQL_BIN_DIR/mysql -h${MYSQL_HOST} -u${SYS_MANAGER_USER} -p"${SYS_MANAGER_PWD}" -P${MYSQL_PORT} mysql -Ne "
        set sql_log_bin = OFF;
        set global slow_query_log = 0;
        drop table if exists slow_log_bak;
        create table if not exists slow_log_new like slow_log;
        rename table slow_log to slow_log_bak,slow_log_new to slow_log;
        set global slow_query_log = 1;
        "
        print_info "慢日志轮询处理完成."
    else
      print_info "当前库为从库，不执行任何操作."
    fi
}

function add_job_crontab(){
    if ! grep -F -q "slow_log_rotate.sh" /etc/crontab; then
        print_info "添加slow_log_rotate定时任务,默认为每月1日凌晨4点执行."
    cat >> /etc/crontab << EOF
# 每一个月1号凌晨4点执行一次[slow_log_rotate.sh]
0 4 1 * * root /bin/bash ${CURRENT_DIR}/$(basename "$0") rotate >> /var/log/slow_log_rotate.log 2>&1
EOF
    print_info "添加[慢日志管理]定时任务完成."
    else
        print_warning "已存在slow_log_rotate定时任务，不执行任何操作."
    fi
}

if [ "$1" = "addcron" ]; then
  add_job_crontab 
elif [ "$1" = "rotate" ]; then
  slow_log_rotate
elif [ "$1" = "delete" ]; then
  print_info "卸载定时任务[慢日志管理] slow_log_rotate.sh..."
  sed -i '/slow_log_rotate.sh/d' /etc/crontab
  sed -i '/slow_log_rotate.sh/d' /etc/crontab
  print_info "卸载[慢日志管理]完成."
else
  printf "Usage:
      $0 rotate  执行慢日志轮询切换
      $0 addcron 添加定时任务[/etc/crontab],默认为每月1号凌晨4点执行
      $0 delete  删除[/etc/crontab]中慢日志轮询切换定时任务\n"
fi

