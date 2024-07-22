#!/bin/bash

CURRENT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )
PARENT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." >/dev/null 2>&1 && pwd )

source $CURRENT_DIR/mysql.sh
source ${PARENT_DIR}/conf/recovery/full_rec.conf

XTRABACKUP_PATH=`which xtrabackup`
# 恢复日志
BACKUP_LOG="$PARENT_DIR/log/recovery.log"
ERROR_LOG="$PARENT_DIR/log/recovery_error.log"
OLD_DATA_DIR=${DATA_DIR}_$(date "+%Y%m%d%H%M%S")
TMP_BACKUP_NAME="backup_$(date "+%Y%m%d%H%M%S")"

# 可根据需求调整
DATA_DIR=$DATA_DIR
CONFIG_FILE=$MYCNF_DIR
START_CMD="systemctl start mysqld$MYSQL_PORT"
STOP_CMD="systemctl stop mysqld$MYSQL_PORT"
SOCKET_DIR=$SOCKET_DIR
USERNAME=$SUPER_USER
PASSWORD=$SUPER_PASSWORD



## 安装解压工具qpress
install_qpress(){
    if [ ! -a /usr/bin/qpress ];then
        print_info "将 qpress工具 拷贝到 /usr/bin"
        chmod 775 $PARENT_DIR/lib/qpress
        cp $PARENT_DIR/lib/qpress /usr/bin
    fi
}

## 解包xbstream文件
xbstream_files(){
    if [ -a $BACKUP_FLIE_DIR/$BACKUP_FLIE_NAME ];then
        mkdir -p $BACKUP_FLIE_DIR/$TMP_BACKUP_NAME
        cat $BACKUP_FLIE_DIR/$BACKUP_FLIE_NAME | xbstream -x -C $BACKUP_FLIE_DIR/$TMP_BACKUP_NAME
    else
        print_error "备份文件不存在"
        exit 1
    fi
}

## 解压
xtrabackup_decompress(){
    #echo "$XTRABACKUP_PATH --decompress --remove-original --target-dir=$BACKUP_FLIE_DIR/$TMP_BACKUP_NAME >> $BACKUP_LOG"
    $XTRABACKUP_PATH --decompress --remove-original --target-dir=$BACKUP_FLIE_DIR/$TMP_BACKUP_NAME >> $BACKUP_LOG 2>&1 || print_error "解压失败,可查看$BACKUP_LOG 获取详细信息"
}

# prepare
xtrabackup_prepare(){
    local xtra_backup_dir=$1
    $XTRABACKUP_PATH --prepare --target-dir=$xtra_backup_dir >> $BACKUP_LOG 2>&1 || print_error "prepare执行失败,可查看$BACKUP_LOG 获取详细信息"
}

# 参数检查
check_diff_params(){
    # 检查参数 innodb_data_file_path
    local source_innodb_data_file=$(cat $BACKUP_FLIE_DIR/$TMP_BACKUP_NAME/backup-my.cnf  |grep innodb_data_file_path|grep -v -E '^#'|awk -F "=" '{print $2}'|sed 's/[[:space:]]//g')
    local target_innodb_data_file=$(cat $CONFIG_FILE  |grep innodb_data_file_path|grep -v -E '^#'|awk -F "=" '{print $2}'|sed 's/[[:space:]]//g')
    if [ "$source_innodb_data_file" = "" ];then
        source_innodb_data_file="ibdata1:12M:autoextend"
    fi
    if [ "$target_innodb_data_file" = "" ];then
        target_innodb_data_file="ibdata1:12M:autoextend"
    fi
    if [ "${source_innodb_data_file}" != "${target_innodb_data_file}" ];then
        print_error "请将本地cnf文件中的innodb_data_file_path 值修改为${source_innodb_data_file},当前值为:$target_innodb_data_file"
        exit 1
    fi
    # 检查参数 innodb_page_size
    local source_innodb_page_size=$(cat $BACKUP_FLIE_DIR/$TMP_BACKUP_NAME/backup-my.cnf  |grep innodb_page_size|grep -v -E '^#'|awk -F "=" '{print $2}'|sed 's/[[:space:]]//g')
    local target_innodb_page_size=$(cat $CONFIG_FILE |grep innodb_page_size|grep -v -E '^#'|awk -F "=" '{print $2}'|sed "s/[[:space:]]//g")
    if [ "$target_innodb_page_size" = "" ];then
        target_innodb_page_size="16384"
    fi
    if [ "$source_innodb_page_size" = "" ];then
        source_innodb_page_size="16384"
    fi
    if [ "$source_innodb_page_size" != "$target_innodb_page_size" ];then
        print_error "请将本地cnf文件中的innodb_page_size 值修改为${source_innodb_page_size},当前值为:$source_innodb_page_size"
        exit 1
    fi
    # 检查参数 server_id
    if [ "$RECOVERY_TYPE" != "full" ] && [ "$RECOVERY_TYPE" != "local_recovery" ];then
        local source_server_id=$(cat $BACKUP_FLIE_DIR/$TMP_BACKUP_NAME/backup-my.cnf  |grep server_id|grep -v -E '^#'|awk -F "=" '{print $2}'|sed 's/[[:space:]]//g')
        local target_server_id=$(cat $CONFIG_FILE |grep server_id|grep -v -E '^#'|awk -F "=" '{print $2}'|sed 's/[[:space:]]//g')
        if [ "$source_server_id" = "" ];then
            source_server_id="1"
        fi
        if [ "$target_server_id" = "" ];then
            target_server_id="1"
        fi
        if [ "$source_server_id" = "$target_server_id" ];then
            print_error "当前MySQL配置文件中 server_id 不能与源库相同"
            exit 1
        fi
    fi
}

xtrabackup_backup_recover(){
    local xtra_backup_dir=$1
    $XTRABACKUP_PATH --defaults-file=$CONFIG_FILE --move-back --target-dir=$xtra_backup_dir >> $BACKUP_LOG 2>&1 || print_error "恢复失败,可查看$BACKUP_LOG 获取详细信息"
}


move_datadir(){
    if [ -a $DATA_DIR ];then
        mv $DATA_DIR $OLD_DATA_DIR
    fi
}

get_replica_version(){
    if [ $MYSQL_VERSION \> "8.0.22" ];then
        replica_statement="replica"
        source_statement="SOURCE"
        change_statement="CHANGE REPLICATION SOURCE TO"
    else
        replica_statement="slave"
        source_statement="MASTER"
        change_statement="CHANGE MASTER TO"
    fi
}

set_skip_replica_start(){
    local skip_exist=$(cat $CONFIG_FILE | grep skip_${replica_statement}_start=1 | wc -l)
    if [ $skip_exist = "0" ];then
        echo -e "[mysqld]\nskip_${replica_statement}_start=1">>$CONFIG_FILE
    fi
}

reset_replica_all(){
    $MYSQL_BIN_DIR/mysql -u$USERNAME -p$PASSWORD -S$SOCKET_DIR -e"reset ${replica_statement} all;" >>$ERROR_LOG 2>&1 || print_error "清除复制信息失败，可查看$ERROR_LOG 获取详细信息"
}

del_skip_replica_start(){
    local text1=$(tail -1 $CONFIG_FILE)
    if [ "$text1" = "skip_${replica_statement}_start=1" ];then
        sed -i '$d' $CONFIG_FILE
        sed -i '$d' $CONFIG_FILE
    fi
}

get_master_ip(){
    local master_info=$($MYSQL_BIN_DIR/mysql -u$USERNAME -p$PASSWORD -S$SOCKET_DIR -e"SELECT concat(host,':',port) FROM performance_schema.replication_connection_configuration" 2>> $ERROR_LOG)
    # 检查命令是否成功执行
    if [ $? -ne 0 ]; then
    print_error "获取服务器主信息失败，可查看 $ERROR_LOG 获取详细信息"
    else
    # 将输出赋值给 master_info
    print_info "当前从库的主服务器为: $master_info"
    fi
}


xtrabackup_recovery(){
    print_info "开始执行恢复,日志路径:[$BACKUP_LOG],[$ERROR_LOG]..."
    print_info "安装解压工具qpress..."
    install_qpress
    print_info "解包xbstream文件..."
    xbstream_files
    print_info "使用qpress解压..."
    xtrabackup_decompress
    print_info "检查参数设置是否正确..."
    check_diff_params
    print_info "prepare..."
    xtrabackup_prepare $BACKUP_FLIE_DIR/$TMP_BACKUP_NAME
    print_info "停止mysql..."
    $STOP_CMD
    print_info "移动原数据文件..."
    move_datadir
    print_info "恢复中..."
    xtrabackup_backup_recover $BACKUP_FLIE_DIR/$TMP_BACKUP_NAME
    print_info "为数据目录授权..."
    chown -R mysql:mysql $DATA_DIR
    if [ "$RECOVERY_TYPE" != "from_slave" ] && [ "$RECOVERY_TYPE" != "local_recovery" ];then
        get_replica_version
        print_info "设置 --skip-replica-start=on..."
        set_skip_replica_start
    fi
    print_info "启动数据库..."
    $START_CMD
    if [ "$RECOVERY_TYPE" != "from_slave" ] && [ "$RECOVERY_TYPE" != "local_recovery" ];then
        print_info "reset replica all ..."
        reset_replica_all
        print_info "删除 --skip-replica-start=on..."
        del_skip_replica_start
    fi
}

# useage 
function useage(){
  printf "Usage:  
    $0 full                           全量恢复，恢复成为一个单独的MySQL实例
    $0 from_slave                     从集群的slave中备份而来，恢复后自动建立主从，主为备份原slave时候的主
    $0 as_slave [master_ip]           恢复后作为从库加入，需要指定master,默认使用的是mysql.conf配置文件中的REPL_USER用户    
    $0 local_recovery                 是在本机进行的备份恢复，不做 server_id 需要不一致的校验.        	    
"
  exit 1
}

RECOVERY_TYPE=$1
if [ "$1" = "full" ];then
    xtrabackup_recovery
# 直接是从集群的从库
elif [ "$1" = "from_slave" ];then
    xtrabackup_recovery
    get_master_ip
elif [ "$1" = "as_slave" ];then
    if [[ -n "$2" ]];then
      xtrabackup_recovery
      $CURRENT_DIR/rejoin_as_slave.sh $2
      get_master_ip
    else
      print_error "需要指定主的IP"
    fi
elif [ "$1" = "local_recovery" ];then
    xtrabackup_recovery
else
  useage
fi

if [[ $DEL_OLD_DATA = 1 ]]&& [[ ${OLD_DATA_DIR} =~ "_" ]];then
    print_info "删除原数据目录..."
    rm -rf $OLD_DATA_DIR
fi

# print_info "删除已使用的备份文件..."
# if [[ ${TMP_BACKUP_NAME} =~ "backup" ]];then
#     rm -rf $BACKUP_FLIE_DIR/$TMP_BACKUP_NAME
# fi

if [[ $DEL_BACKUP = 1 ]];then
    print_info "删除备份文件..."
    rm -f $BACKUP_FLIE_DIR/$BACKUP_FLIE_NAME
fi
print_info "全量恢复完成"