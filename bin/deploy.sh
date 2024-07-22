#!/bin/bash
set -e

CURRENT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )
PARENT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." >/dev/null 2>&1 && pwd )
INSTALL_BASE_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )/../.." >/dev/null 2>&1 && pwd )
# 安装目录名称，如：Deploy_MySQL
INSTALL_BASE_NAME=$(basename "$PARENT_DIR")

# 加载配置文件
source $CURRENT_DIR/mysql.sh
source $CURRENT_DIR/sys.sh

# 部署单机
function delpoy_single(){
    #check_ip_exists_on_localserver $IPADDR
    if [ "$MYSQL_VERSION" = "5.7" ];then
        $CURRENT_DIR/install_mysql.sh $PARENT_DIR/conf/template/5.7/my.cnf.single
    elif [ "$MYSQL_VERSION" = "8.0" ];then
        $CURRENT_DIR/install_mysql.sh $PARENT_DIR/conf/template/8.0/my.cnf.single
    else
        print_error "请检查配置文件版本信息，仅支持 5.7/8.0 ！"
        exit 1
    fi
}

# 单独部署主或从
function delpoy_master_or_slave(){
    local masterslave_type=$1
    if [ "$MYSQL_VERSION" = "5.7" ];then
        $CURRENT_DIR/install_mysql.sh $PARENT_DIR/conf/template/5.7/my.cnf.$masterslave_type
    elif [ "$MYSQL_VERSION" = "8.0" ];then
        $CURRENT_DIR/install_mysql.sh $PARENT_DIR/conf/template/8.0/my.cnf.$masterslave_type
    else
        print_error "请检查配置文件版本信息，仅支持 5.7/8.0 ！"
        exit 1
    fi
}


function change_master_by_socket(){
	local master_ip=$1
        # 不为主的执行change master
        if [ $IPADDR != $master_ip ];then
            print_info "建立主从关系，主[$master_ip],从[$IPADDR]..."
            local sql="reset master;$CHANGE_STATEMENT ${SOURCE_STATEMENT}_HOST = '$master_ip',${SOURCE_STATEMENT}_PORT = $MYSQL_PORT,${SOURCE_STATEMENT}_USER = '$REPL_USER',${SOURCE_STATEMENT}_PASSWORD = '${REPL_PASSWORD}',${SOURCE_STATEMENT}_AUTO_POSITION = 1; start $REPLICATION_STATEMENT;set global super_read_only=1;set global read_only=1;"
            print_info "从库执行 reset master;$CHANGE_STATEMENT..."
            #print_info "从库执行 $sql..."
            do_exec_sql_by_socket 'root' "${INIT_PASSWORD}" $SOCKET_DIR "$sql"

            print_info "检查主从关系状态:[$master_ip],从[$IPADDR]..."
            # 等待两秒，让回放下sql_thread，防止检查太快无法得到正确主从关系
            sleep 5
            check_slave_status $IPADDR $REPL_USER $REPL_PASSWORD $MYSQL_PORT
        fi
}

# 部署一个从库
function deploy_as_slave(){
   local master_ip=$1
   delpoy_master_or_slave slave
   change_master_by_socket $master_ip
}

# 单独主从模式
function delpoy_master_with_slave(){
    local arr_nodes=($(IFS=,; echo $SERVER_GROUP | tr ',' '\n'))
    local master_ip=${arr_nodes[0]}
    for hostip in "${arr_nodes[@]}";do
        local check_ip_exists=$(check_ip_exists_on_localserver $hostip)
        if [ $hostip == $master_ip ];then
            local masterslave_type='master'
        else 
            local masterslave_type='slave'
        fi
        # 在本机执行
        if [ $check_ip_exists == "Y" ];then
          print_info "######################## 执行本机安装，目标机[$hostip],角色为[$masterslave_type] "########################
          delpoy_master_or_slave $masterslave_type
	  if [ ${hostip} != $master_ip ];then
	    change_master_by_socket "${master_ip}"
	  fi
	  print_info "修改配置文件[my$MYSQL_PORT.cnf],将参数 read_only/super_read_only 设置为默认重启打开,防止脑裂情况下数据错乱."
	  sed -i 's/^#read_only = 1/read_only = 1/' $MYSQL_DATA_DIR/mysql$MYSQL_PORT/my$MYSQL_PORT.cnf
	  sed -i 's/^#super_read_only = 1/super_read_only = 1/' $MYSQL_DATA_DIR/mysql$MYSQL_PORT/my$MYSQL_PORT.cnf
        else
            print_info "######################## 执行远程安装，目标机[$hostip],角色为[$masterslave_type] ########################"
            # 将安装文件远程拷贝到目标机
            local deploy_files=$(ssh root@${hostip} -p $SERVER_PORT "[ -d ${MYSQL_DATA_DIR}/$INSTALL_BASE_NAME ] && echo 0 || echo 1")
            if [ $deploy_files -eq 1 ];then
                print_info "正在将安装程序{$PARENT_DIR}远程拷贝到目标机[$hostip]"
                scp -r -P $SERVER_PORT $PARENT_DIR  ${hostip}:${MYSQL_DATA_DIR}
                #echo "-------- scp -r -P $SERVER_PORT $PARENT_DIR  ${hostip}:${MYSQL_DATA_DIR}"
                print_info "修改配置文件中的IPADDR为 ${hostip}"
                ssh root@${hostip} -p $SERVER_PORT "sed -i 's/IPADDR=.*/IPADDR=$hostip/' ${MYSQL_DATA_DIR}/$INSTALL_BASE_NAME/conf/mysql.cnf"
            fi
            deploy_dir=$(echo "$CURRENT_DIR" | awk -F '/' '{print $(NF-1)"/"$NF}')
            ssh -n root@${hostip} -p $SERVER_PORT "${MYSQL_DATA_DIR}/$deploy_dir/deploy.sh $masterslave_type"
	    if [ ${hostip} != $master_ip ];then
	      ssh -n root@${hostip} -p $SERVER_PORT "${MYSQL_DATA_DIR}/$deploy_dir/deploy.sh change_master $master_ip"
	    fi
	    print_info "修改配置文件[my$MYSQL_PORT.cnf],将参数 read_only/super_read_only 设置为默认重启打开,防止脑裂情况下数据错乱."
	    ssh root@${hostip} -p $SERVER_PORT "sed -i 's/^#read_only = 1/read_only = 1/' $MYSQL_DATA_DIR/mysql$MYSQL_PORT/my$MYSQL_PORT.cnf"
	    ssh root@${hostip} -p $SERVER_PORT "sed -i 's/^#super_read_only = 1/super_read_only = 1/' $MYSQL_DATA_DIR/mysql$MYSQL_PORT/my$MYSQL_PORT.cnf"
        fi
    done
}

# 添加 VIP
function vip_init_add(){
  print_info "在主库[$MASTER_IP]添加 VIP"
  local arr_nodes=($(IFS=','; echo $SERVER_GROUP | tr ',' '\n'))
  local MASTER_IP=${arr_nodes[0]}  
  for hostip in "${arr_nodes[@]}";do
    if [ ${hostip} == $MASTER_IP ];then
	local check_ip_exists=$(check_ip_exists_on_localserver $hostip)
        if [[ $check_ip_exists == "Y" ]];then
          echo "$CURRENT_DIR/vip_add_or_del.sh add"
          $CURRENT_DIR/vip_add_or_del.sh add
        else
          #echo "ssh -n root@${MASTER_IP} -p $SERVER_PORT \"${MYSQL_DATA_DIR}/$deploy_dir/vip_add_or_del.sh add\""
          ssh -n root@${MASTER_IP} -p $SERVER_PORT "${MYSQL_DATA_DIR}/$deploy_dir/vip_add_or_del.sh add"
        fi
    fi
  done
}

# 创建ha用户并部署高可用组件
function deploy_replication_manager(){
    local file_found=$(find $PARENT_DIR/lib -type f -name "*replication-manager*" -print -quit)
    if [[ ! -e "$file_found" ]]; then
        print_error "请先下载 replication-manager 到 lib 目录，也可以使用 download_lib.sh 脚本进行下载。"
    fi

    local arr_nodes=($(IFS=','; echo $SERVER_GROUP | tr ',' '\n'))
    local MASTER_IP=${arr_nodes[0]}

    print_info "创建ha管理用户[$HA_USER]..."
    local sql="create user if not exists '$HA_USER' identified by '${HA_PASSWORD}';
    grant SUPER, PROCESS, REPLICATION CLIENT,REPLICATION SLAVE, RELOAD on *.* to '$HA_USER';
    GRANT SELECT ON mysql.slave_master_info TO '$HA_USER';
    grant  select on performance_schema.* to '$HA_USER';
    grant  select on mysql.user to '$HA_USER';
    grant  select on mysql.slow_log to '$HA_USER';"
    do_exec_sql $MASTER_IP $SUPER_USER "${SUPER_PASSWORD}" $MYSQL_PORT "$sql"
    print_info "用户['$HA_USER']创建完成"

    $CURRENT_DIR/install_replication_manager.sh install

    print_info "配置集群监控管理VIP管理脚本[vip_check_and_manager.sh]..."
    cat >> /etc/crontab << EOF
# 每分钟自行一次检测
* * * * * root /bin/bash /etc/replication-manager/script/vip_check_and_manager.sh >> /etc/replication-manager/script/manager_vip.log 2>&1
EOF

    print_info "######################## 集群安装完成 ########################"
}

# 卸载集群所有MySQL
function uninstall_cluster_all(){
    local arr_nodes=($(IFS=,; echo $SERVER_GROUP | tr ',' '\n'))
    local master_ip=${arr_nodes[0]}
    for hostip in "${arr_nodes[@]}";do
	    print_info "------------ 开始卸载 ${hostip} 上的 MySQL ... ------------"
	    local check_ip_exists=$(check_ip_exists_on_localserver $hostip)
        if [ $check_ip_exists == "Y" ];then
	    $CURRENT_DIR/uninstall_mysql.sh $MYSQL_PORT
        local check_vip_exists=$(check_ip_exists_on_localserver $VIP)
        if [ $check_vip_exists == "Y" ];then
            $CURRENT_DIR/vip_add_or_del.sh del
        fi
	else
	    deploy_dir=$(echo "$CURRENT_DIR" | awk -F '/' '{print $(NF-1)"/"$NF}')
        ssh -n root@${hostip} -p $SERVER_PORT "${MYSQL_DATA_DIR}/$INSTALL_BASE_NAME/bin/uninstall_mysql.sh $MYSQL_PORT"
        ssh -n root@${hostip} -p $SERVER_PORT "${MYSQL_DATA_DIR}/$INSTALL_BASE_NAME/bin/vip_add_or_del.sh del"
	fi
	print_info "${hostip} 上的 MySQL 已卸载完成 ..."
    done

    print_info "卸载[Vip管理]定时任务 vip_check_and_manager.sh..."
    sed -i '/vip_check_and_manager.sh/d' /etc/crontab

    print_info "卸载高可用组件replication-manager ..."
    $CURRENT_DIR/install_replication_manager.sh uninstall

}

# 卸载本机单个MySQL
function uninstall_mysql(){
    print_info "开始执行卸载 MySQL[$MYSQL_PORT]"
    $CURRENT_DIR/uninstall_mysql.sh $MYSQL_PORT
    print_info "${IPADDR} 上的 MySQL 已卸载完成 ..."

}

# useage 
function useage(){
  printf "Usage:  
    $0 single                           单机部署
    $0 master/slave                     单独部署master或slave
    $0 masterslave                      部署主从模式（非高可用）
    $0 ha				 部署高可用模式
    $0 as_slave [ip]		         部署一个从库,同时建立好主从关系,需传入 master_ip
    $0 change_master [ip]	         执行change master做主从,传入 master_ip
    $0 uninstall_cluster_all	         卸载集群,包括所有MySQL与高可用组件
    $0 uninstall			 卸载本机的 MySQL	    
"
  exit 1
}

function main(){
  if [ -n "$1" ];then
        if [ $1 == "single" ];then
            delpoy_single
        elif [ $1 == "master" ] || [ $1 == "slave" ];then
            delpoy_master_or_slave $1
        elif [ $1 == "masterslave" ];then
            delpoy_master_with_slave
    ##### 部署高可用模式 #####
	elif [ $1 == "ha" ];then
        # 部署主从
        delpoy_master_with_slave
        # 在主库添加VIP
        vip_init_add
        # 创建ha用户并部署高可用组件
	    deploy_replication_manager
	elif [ $1 == "as_slave" ];then
	    if [[ -n "$2" ]];then
               deploy_as_slave $2
            else
               print_error "需要指定主的IP"
               useage
            fi
	elif [[ $1 == "change_master" ]]; then
            if [[ -n "$2" ]];then
	       change_master_by_socket $2
            else
	       print_error "需要指定主的IP"
	       useage
            fi
	elif [ $1 == "uninstall_cluster_all" ];then
	    uninstall_cluster_all
	elif [ $1 == "uninstall" ];then
            uninstall_mysql
        else
            useage
        fi
  else 
    useage
  fi
}

main $1 $2
