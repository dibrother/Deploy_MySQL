#!/bin/bash
set -e

CURRENT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )
PARENT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." >/dev/null 2>&1 && pwd )

# 加载配置文件信息
# 加载配置文件
source $CURRENT_DIR/mysql.sh
cluster_name=db${MYSQL_PORT}

# 检查传入参数
check_params(){
  if [ ! $HA_USER ] || [ ! ${HA_PASSWORD} ] || [ ! $SERVER_GROUP ];then
    print_error "部署高可用需要的参数设置不全，请检查！"
    exit 1
  fi

  if [ $SERVER_GROUP ];then
    print_info "检测传入的SERVER_GROUP，值为:[$SERVER_GROUP]"
    local arr_nodes=($(IFS=','; echo $SERVER_GROUP | tr ',' '\n'))
    if [ ${#arr_nodes[@]} -lt 2 ];then
       print_error "部署高可用必须有2节点及以上。"
       exit 1
    fi
  fi
}

# # 创建管理用户
#function create_ha_monitor_user(){
#   # 仅主库创建
#   print_info "创建ha管理用户[$HA_USER]..."
#   local arr_nodes=($(IFS=','; echo $SERVER_GROUP | tr ',' '\n'))
#   local MASTER_IP=${arr_nodes[0]}
#   local sql="create user if not exists '$HA_USER' identified by '${HA_PASSWORD}';grant SUPER, PROCESS, REPLICATION CLIENT,REPLICATION SLAVE, RELOAD on *.* to '$HA_USER';GRANT SELECT ON mysql.slave_master_info TO '$HA_USER';grant  select on performance_schema.* to '$HA_USER';grant  select on mysql.user to '$HA_USER';"
#   do_exec_sql $MASTER_IP $SUPER_USER "${SUPER_PASSWORD}" -P$MYSQL_PORT "$sql"
#   print_info "用户['$HA_USER']创建完成"
# }

# 安装 replication-manager
install_replication_manager(){
  package_manager=$(detect_package_manager)
  # 未安装
  if ! command -v replication-manager &> /dev/null; then
    # 安装文件存在
    local file_found=$(find $PARENT_DIR/lib -type f -name "*replication-manager*" -print -quit)
    if [[ -e "$file_found" ]]; then
      print_info "安装 replication-manager..."
      if [ $package_manager = "yum" ];then
        #yum install -y $PARENT_DIR/lib/replication-manager*.rpm
        rpm -ivh $PARENT_DIR/lib/replication-manager*.rpm
      elif [ $package_manager = "apt-get" ];then
        dpkg -i $PARENT_DIR/lib/replication-manager-osc*.deb
      fi
    else
      print_error "请先下载 replication-manager 到 lib 目录."
    fi
  else
    print_info "组件 replication-manager 已安装."
  fi
}

# 配置 /etc/replication-manager/cluster.d/cluster1.toml
# 默认会选择SERVER_GROUP的前两个作为优先切换实例
replication_manager_config_cluster(){
  if [ -f /etc/replication-manager/config.toml ];then
    mv /etc/replication-manager/config.toml /etc/replication-manager/config.toml.bak.$(date '+%Y%m%d%H%M%S')
  fi
  cp $PARENT_DIR/conf/template/ha/config.toml /etc/replication-manager/config.toml
  cp $PARENT_DIR/conf/template/ha/cluster1.toml /etc/replication-manager/cluster.d/cluster1.toml
  local arr_nodes=($(IFS=','; echo $SERVER_GROUP | tr ',' '\n'))
  for i in "${arr_nodes[@]}"; do
      local db_server_hosts+="$i:${MYSQL_PORT},"
  done
  # 删除最后的 ,
  local db_server_hosts=${db_server_hosts%,}
  #if [ ${#arr_nodes[@]} -gt 2 ];then
  local db_server_prefered_master=${db_server_hosts%,*}
  #else
  #  local db_server_prefered_master=${db_server_hosts}
  #fi

  # sed 根据行号替换值
  sed -i 's/db-servers-hosts.*/db-servers-hosts = '\"${db_server_hosts}\"'/' /etc/replication-manager/cluster.d/cluster1.toml
  sed -i 's/db-servers-prefered-master.*/db-servers-prefered-master = '\"${db_server_prefered_master}\"'/' /etc/replication-manager/cluster.d/cluster1.toml
  sed -i 's/db-servers-credential.*/db-servers-credential = '\"${HA_USER}:${HA_PASSWORD}\"'/' /etc/replication-manager/cluster.d/cluster1.toml
  sed -i 's/replication-credential.*/replication-credential = '\"${REPL_USER}:${REPL_PASSWORD}\"'/' /etc/replication-manager/cluster.d/cluster1.toml
  sed -i 's%backup-mysqlbinlog-path =.*%backup-mysqlbinlog-path = '\"$(echo $MYSQL_BIN_DIR)/mysqlbinlog\"'%' /etc/replication-manager/cluster.d/cluster1.toml
  sed -i 's%backup-mysqlclient-path =.*%backup-mysqlclient-path = '\"$(echo $MYSQL_BIN_DIR)/mysql\"'%' /etc/replication-manager/cluster.d/cluster1.toml
}

# 配置 /etc/replication-manager/config.toml
replication_manager_config(){
  sed -i 's%api-credentials = .*%api-credentials = '\"admin:$(echo $HA_HTTP_PASSWORD)\"'%' /etc/replication-manager/config.toml
  sed -i 's%http-port =.*%http-port = '\"${HA_PORT}\"'%' /etc/replication-manager/config.toml
}

# 配置VIP漂移脚本
config_vip_drift_scripts(){
    local REPLICATION_CURRENT_DIR="/etc/replication-manager/script"
    mkdir -p $REPLICATION_CURRENT_DIR
    cp $PARENT_DIR/conf/template/ha/vip_down.sh /etc/replication-manager/script
    cp $PARENT_DIR/conf/template/ha/vip_up.sh /etc/replication-manager/script
    cp $PARENT_DIR/conf/template/ha/vip_check_and_manager.sh /etc/replication-manager/script
    cp $PARENT_DIR/lib/dingtalk_send /etc/replication-manager/script
    

    #sed -i 's/mysql_user=.*/mysql_user='$(echo \'$HA_USER\')'/' ${REPLICATION_CURRENT_DIR}/vip_down.sh
    #sed -i 's/mysql_password=.*/mysql_password='$(echo \'$HA_PASSWORD\')'/' ${REPLICATION_CURRENT_DIR}/vip_down.sh
    sed -i 's/interface=.*/interface='$(echo $NET_WORK_CARD_NAME)'/' ${REPLICATION_CURRENT_DIR}/vip_down.sh
    sed -i 's/vip=.*/vip='$(echo $VIP)'/' ${REPLICATION_CURRENT_DIR}/vip_down.sh
    sed -i 's/ssh_options=.*/ssh_options='$(echo \'-p$SERVER_PORT\')'/' ${REPLICATION_CURRENT_DIR}/vip_down.sh
    sed -i 's/DINGDING_SWITCH=.*/DINGDING_SWITCH='$(echo $DINGDING_SWITCH)'/' ${REPLICATION_CURRENT_DIR}/vip_down.sh
    sed -i 's/MSG_TITLE=.*/MSG_TITLE='\'数据库切换告警\''/' ${REPLICATION_CURRENT_DIR}/vip_down.sh
    sed -i 's%WEBHOOK_URL=.*%WEBHOOK_URL='$(echo \'$WEBHOOK_URL\')'%' ${REPLICATION_CURRENT_DIR}/vip_down.sh
    sed -i 's/SECRET=.*/SECRET='$(echo \'$SECRET\')'/' ${REPLICATION_CURRENT_DIR}/vip_down.sh
    sed -i 's/SEND_TYPE=.*/SEND_TYPE='$(echo \'$SEND_TYPE\')'/' ${REPLICATION_CURRENT_DIR}/vip_down.sh
    sed -i 's/IS_AT_ALL=.*/IS_AT_ALL='$(echo \'$IS_AT_ALL\')'/' ${REPLICATION_CURRENT_DIR}/vip_down.sh
    sed -i 's/AT_MOBILES=.*/AT_MOBILES='$(echo \'$AT_MOBILES\')'/' ${REPLICATION_CURRENT_DIR}/vip_down.sh 

    #sed -i 's/mysql_user=.*/mysql_user='$(echo \'$HA_USER\')'/' ${REPLICATION_CURRENT_DIR}/vip_up.sh
    #sed -i 's/mysql_password=.*/mysql_password='$(echo \'$HA_PASSWORD\')'/' ${REPLICATION_CURRENT_DIR}/vip_up.sh
    sed -i 's/interface=.*/interface='$(echo $NET_WORK_CARD_NAME)'/' ${REPLICATION_CURRENT_DIR}/vip_up.sh
    sed -i 's/vip=.*/vip='$(echo $VIP)'/' ${REPLICATION_CURRENT_DIR}/vip_up.sh
    sed -i 's/ssh_options=.*/ssh_options='$(echo \'-p$SERVER_PORT\')'/' ${REPLICATION_CURRENT_DIR}/vip_up.sh
    sed -i 's/DINGDING_SWITCH=.*/DINGDING_SWITCH='$(echo $DINGDING_SWITCH)'/' ${REPLICATION_CURRENT_DIR}/vip_up.sh
    sed -i 's/MSG_TITLE=.*/MSG_TITLE='\'数据库切换告警\''/' ${REPLICATION_CURRENT_DIR}/vip_up.sh
    sed -i 's%WEBHOOK_URL=.*%WEBHOOK_URL='$(echo \'$WEBHOOK_URL\')'%' ${REPLICATION_CURRENT_DIR}/vip_up.sh
    sed -i 's/SECRET=.*/SECRET='$(echo \'$SECRET\')'/' ${REPLICATION_CURRENT_DIR}/vip_up.sh
    sed -i 's/SEND_TYPE=.*/SEND_TYPE='$(echo \'$SEND_TYPE\')'/' ${REPLICATION_CURRENT_DIR}/vip_up.sh
    sed -i 's/IS_AT_ALL=.*/IS_AT_ALL='$(echo \'$IS_AT_ALL\')'/' ${REPLICATION_CURRENT_DIR}/vip_up.sh
    sed -i 's/AT_MOBILES=.*/AT_MOBILES='$(echo \'$AT_MOBILES\')'/' ${REPLICATION_CURRENT_DIR}/vip_up.sh   

    sed -i 's/interface=.*/interface='$(echo $NET_WORK_CARD_NAME)'/' ${REPLICATION_CURRENT_DIR}/vip_check_and_manager.sh
    sed -i 's/vip=.*/vip='$(echo $VIP)'/' ${REPLICATION_CURRENT_DIR}/vip_check_and_manager.sh
    sed -i 's/ssh_options=.*/ssh_options='$(echo \'-p$SERVER_PORT\')'/' ${REPLICATION_CURRENT_DIR}/vip_check_and_manager.sh
    sed -i 's/mysql_port=.*/mysql_port='$(echo \'$MYSQL_PORT\')'/' ${REPLICATION_CURRENT_DIR}/vip_check_and_manager.sh
    #sed -i 's/ha_http_user=.*/ha_http_user='$(echo \'admin\')'/' ${REPLICATION_CURRENT_DIR}/vip_check_and_manager.sh
    sed -i 's/ha_http_password=.*/ha_http_password='$(echo \'$HA_HTTP_PASSWORD\')'/' ${REPLICATION_CURRENT_DIR}/vip_check_and_manager.sh

    chmod +x /etc/replication-manager/script/*
}

# 清除
uninstall_replication_manager(){
  set +e
  status=$(systemctl is-active replication-manager)
  set -e
  if [ "$status" = "active" ]; then
    print_info "停止replication-manager..."
    systemctl stop replication-manager
  fi
  print_info "卸载replication-manager相关rpm"
  if [[ $SYSTEM_TYPE == "Debian_Ubuntu" ]];then
    local CHK_RESULT=`dpkg -l|grep replication-manager|wc -l`
  else
    local CHK_RESULT=$(rpm -qa|grep replication-manager|wc -l)
  fi

  if [ $CHK_RESULT -gt 1 ];then
    if [[ $SYSTEM_TYPE == "Debian_Ubuntu" ]];then
      apt remove --purge -y replication-manager-osc
    else
      local packages_to_remove=$(rpm -qa | grep '^replication-manager-')
      for package in $packages_to_remove; do
        rpm -e $package
      done
    fi
  fi

  print_info "删除目录：/etc/replication-manager"
  rm -rf /etc/replication-manager
  print_info "删除目录：/usr/share/replication-manager"
  rm -rf /usr/share/replication-manager
  print_info "删除日志文件：/var/log/replication-manager*"
  rm -f /var/log/replication-manager*
  print_info "删除文件：/etc/init.d/replication-manager"
  rm -f /etc/init.d/replication-manager
  print_info "删除文件：/usr/bin/replication-manager-*"
  rm -f  /usr/bin/replication-manager-*
  print_info "删除文件：/etc/systemd/system/replication-manager.service"
  rm -f  /etc/systemd/system/replication-manager.service
}

# 启动
start_replication_manager(){
    systemctl daemon-reload
    systemctl start replication-manager
    print_info "设置为开机自启动..."
    systemctl enable replication-manager
    systemctl status replication-manager
    
}

function useage(){
  printf "Usage: 
            $0 install                安装replication-manager
            $0 uninstall              卸载replication-manager
"

}

function install_replication(){
print_info "######################## 安装高可用组件 replication-manager ########################"
print_info "检查传入参数 ..."
check_params
# 创建管理用户
#create_ha_monitor_user
print_info "安装replication_manager包 ..."
install_replication_manager
print_info "配置集群参数 ..."
replication_manager_config_cluster
print_info "配置服务参数 ..."
replication_manager_config
print_info "更改vip相关 ..."
config_vip_drift_scripts
print_info "启动replication服务 ..."
start_replication_manager
print_info "请在浏览器打开 http://$IPADDR:${HA_PORT} 或  https://$IPADDR:10005 登陆查看"
}

function main(){
  if [ "$1" == "install" ];then
    install_replication
  elif [ "$1" == "uninstall" ];then
    uninstall_replication_manager
  else
    useage
  fi
}

main $1
