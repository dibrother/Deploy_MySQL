#!/bin/bash
set -e
set -o pipefail

CURRENT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )
PARENT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." >/dev/null 2>&1 && pwd )

# 加载配置文件
source $CURRENT_DIR/mysql.sh
source $CURRENT_DIR/sys.sh

# 获取系统包管理器类型  yum/apt-get
package_manager=$(detect_package_manager)

# 安装依赖包
function install_dependency_packages(){
  local package_manager=$(detect_package_manager)
  if [ $package_manager = "yum" ];then
     check_and_install_pkg libaio
     if [ ! -f /usr/lib64/libncurses.so.5 ]; then
       print_error "请检查并设置 libncurses.so.5，可能你需要根据实际情况执行： 
       ln -s /usr/lib64/libncurses.so.6.1 /usr/lib64/libncurses.so.5
       ln -s /usr/lib64/libtinfo.so.6.1 /usr/lib64/libtinfo.so.5"
       exit 1
     fi
    elif [ $package_manager = "apt-get" ];then
      check_and_install_pkg libaio1
      check_and_install_pkg numactl
      check_and_install_pkg libncurses5
      check_and_install_pkg libncursesw5
      check_and_install_pkg libjemalloc2
    fi
}



# 预检查传入参数
function pre_check_params(){
  local ARR=($MYSQL_DATA_DIR $MYSQL_VERSION $MYSQL_PORT $MEMORY_ALLLOW_GB ${INIT_PASSWORD} $IPADDR $SUPER_USER $SUPER_PASSWORD)
  if [ ! "${#ARR[*]}" -eq 8 ];then
    print_error "$0 传入指令参数个数不正确，请检查 mysql.cnf ！"
    exit 1
  fi
}

## 检查端口限制
function check_port_range(){
  if [[ ${MYSQL_PORT} -gt 65535 ]] || [[ ${MYSQLX_PORT} -gt 65535 ]] || [[ ${MYSQL_ADMIN_PORT} -gt 65535 ]];then
    print_error "端口设置超出65535限制,请重新设置端口!
    当前端口值 MySQL port:${MYSQL_PORT},MySQLX port:${MYSQLX_PORT},MYSQL_ADMIN_PORT:${MYSQL_ADMIN_PORT}"
    exit 1
  fi
}

## 检查并创建用户组和用户
function create_mysql_group_and_user(){
  local IS_MYSQL_GROUP=$(grep -w "mysql" /etc/group|wc -l)
  if [ $IS_MYSQL_GROUP -eq 0 ];then
    groupadd mysql
    print_info "mysql用户组创建成功"
  else
    print_info "mysql用户组已存在"
  fi

  local IS_MYSQL_USER=`grep -w "mysql" /etc/passwd|wc -l`
  if [ $IS_MYSQL_USER -eq 0 ];then
    useradd  -g mysql -s /sbin/nologin mysql
    print_info "mysql用户创建成功"
  else
    print_warning "mysql用户已存在"
  fi
}

# 创建 slow_log 管理 crontab 任务
function set_rotate_slow_log(){
  print_info "设置 MySQL 慢日志 crontab 任务管理 "

}

# 卸载系统自带 mariadb
uninstall_mariadb(){
  if [ $package_manager = "yum" ];then
    local chk_result=`rpm -qa|grep mariadb-libs|wc -l`
    if [ $chk_result -gt 0 ];then
      print_warning "卸载默认安装的mariadb"
      local mariadb=`rpm -qa|grep mariadb-libs`
      rpm -e --nodeps $mariadb
    else
      print_info "mariadb 未安装或已被卸载"
    fi
  fi
}

before_install_check(){
   print_info "检查传入参数..."
   pre_check_params
   print_info "检查端口是否设置超出范围..."
   check_port_range
   print_info "检查端口是否被占用..."
   check_port_exists_to_err $MYSQL_PORT
   check_port_exists_to_err $MYSQLX_PORT
   check_port_exists_to_err $MYSQL_ADMIN_PORT
   print_info "检查MySQL安装包是否存在..."
   check_file_not_exists_to_err $PARENT_DIR/lib/$MYSQL_PKG
   print_info "检查数据目录是否为空..."
   check_dir_not_empty_to_err $DATA_DIR
   print_info "检测systemd mysqld服务是否已存在..."
   check_file_already_exists_to_err /usr/lib/systemd/system/mysqld${MYSQL_PORT}.service
}

# 设置系统相关
fix_system_config(){
  print_info "检查是否使用CPU节能策略..."
  check_cpupower
  print_info "关闭防火墙..."
  do_stop_firewalld
  print_info "关闭selinux..."
  do_disable_selinux
  print_info "检查时间同步..."
  check_ntp_status
  # print_info "配置磁盘调度..."
  # comm_set_disk_scheduler $DISK_DEVICE_NAME
  print_info "优化内核参数..."
  do_optimize_kernel_parameters
  print_info "设置swap..."
  do_swap_to_one
  print_info "优化使用资源上限..."
  do_optimize_resource_limits
}

# 解压安装包
function uncompress_pkg(){ 
  if [ -d $BASE_DIR ];then
    print_info "$BASE_DIR 目录已存在..."
  else
    print_info "开始解压缩，可能需要花费几分钟，请耐心等待..."
    mkdir -p $BASE_DIR
    tar xf $PARENT_DIR/lib/$MYSQL_PKG -C $BASE_DIR --strip-components 1
  fi
}

# 配置环境变量
function set_mysql_env(){
  ## 设置环境变量,/etc/profile.d/mysql_set_env.sh ,脚本名称固定
  if [ ! -f /etc/profile.d/mysql_set_env.sh ];then
    echo "export PATH=$PATH:$BASE_DIR/bin" > /etc/profile.d/mysql_set_env.sh
    source /etc/profile.d/mysql_set_env.sh
    print_info "设置环境变量成功"
  else
    local localtime=$(date +%Y%m%d%H%M%S)
    mv /etc/profile.d/mysql_set_env.sh /etc/profile.d/mysql_set_env.sh.$localtime
    print_warning "/etc/profile.d/mysql_set_env.sh 已存在，原文件被重命名为 mysql_set_env.sh.$localtime"
    echo "export PATH=$PATH:$BASE_DIR/bin" > /etc/profile.d/mysql_set_env.sh
    source /etc/profile.d/mysql_set_env.sh
    print_info "设置新环境变量成功"
  fi
}

# 配置my.cnf
## 传入模板路径
## 默认使用对应版本的single模板
function set_my_cnf(){
  if [ -e $MYCNF_DIR ];then
    mv $MYCNF_DIR $MYCNF_DIR.`date +%Y%m%d%H%M%S`
    print_warning "my.cnf 配置文件已存在，源配置文件被重命名为 $MYCNF_DIR.`date +%Y%m%d%H%M%S`"
  fi

  # 拷贝模板
  cp $MYCNF_TEMPLATE $MYCNF_DIR

  # 替换路径
  sed -i 's#^basedir.*$#basedir = '$BASE_DIR'#' $MYCNF_DIR
  sed -i 's#^datadir.*$#datadir = '$DATA_DIR'#' $MYCNF_DIR
  sed -i 's#^tmpdir.*$#tmpdir = '$DATA_DIR'#' $MYCNF_DIR
  sed -i 's#^socket.*$#socket = '$SOCKET_DIR'#' $MYCNF_DIR
  sed -i 's#^mysqlx_socket.*$#mysqlx_socket = '$MYSQLX_SOCKET_DIR'#' $MYCNF_DIR
  # 替换端口
  sed -i 's#^port.*$#port = '$MYSQL_PORT'#' $MYCNF_DIR
  sed -i 's#^mysqlx_port.*$#mysqlx_port = '$MYSQLX_PORT'#' $MYCNF_DIR
  sed -i 's#^admin_port.*$#admin_port = '$MYSQL_ADMIN_PORT'#' $MYCNF_DIR
  # 设置report
  sed -i 's/^#report_host=.*$/report_host='${IPADDR}'/' $MYCNF_DIR
  sed -i 's/^#report_port=.*$/report_port='${MYSQL_PORT}'/' $MYCNF_DIR
  # 替换server_id
  SERVER_ID=`echo "$IPADDR"|awk -F "." '{print $3$4}'`
  sed -i 's#^server_id.*$#server_id = '$SERVER_ID'#' $MYCNF_DIR
  # 设置 innodb_buffer_pool  
  if [ $MEMORY_ALLLOW_GB -le 1 ];then
    sed -i 's/^innodb_buffer_pool_size.*$/#innodb_buffer_pool_size = 4G/' $MYCNF_DIR  #小于1G的就直接使用默认值
  else
    INNODB_BUFFER_POOL_SIZE=`expr $MEMORY_ALLLOW_GB \* 1024 \* 60 / 100 / 128 / 8`
    sed -i 's/^innodb_buffer_pool_size.*$/innodb_buffer_pool_size = '$INNODB_BUFFER_POOL_SIZE'G/' $MYCNF_DIR
  fi
  
  # 根据内存大小调整相关的参数
  if [ $MEMORY_ALLLOW_GB -lt 4 ];then
    sed -i 's/^read_buffer_size/#&/' $MYCNF_DIR
    sed -i 's/^read_rnd_buffer_size/#&/' $MYCNF_DIR
    sed -i 's/^sort_buffer_size/#&/' $MYCNF_DIR
    sed -i 's/^join_buffer_size/#&/' $MYCNF_DIR
    sed -i 's/^bulk_insert_buffer_size/#&/' $MYCNF_DIR
    sed -i 's/^tmp_table_size/#&/' $MYCNF_DIR
    sed -i 's/^max_heap_table_size/#&/' $MYCNF_DIR
    sed -i 's/^binlog_cache_size.*$/binlog_cache_size = 2M/' $MYCNF_DIR
  elif [ $MEMORY_ALLLOW_GB -ge 4 ] && [ $MEMORY_ALLLOW_GB -lt 16 ];then
    sed -i 's/^read_buffer_size.*$/read_buffer_size = 2M/' $MYCNF_DIR
    sed -i 's/^read_rnd_buffer_size.*$/read_rnd_buffer_size = 2M/' $MYCNF_DIR
    sed -i 's/^sort_buffer_size.*$/sort_buffer_size = 2M/' $MYCNF_DIR
    sed -i 's/^join_buffer_size.*$/join_buffer_size = 2M/' $MYCNF_DIR
    sed -i 's/^bulk_insert_buffer_size.*$/bulk_insert_buffer_size = 16M/' $MYCNF_DIR
  fi
}

# 配置systemctl 启停脚本
add_systemd_mysql(){
if [[ $MYSQL_VERSION = "8.0" ]];then
cat > /usr/lib/systemd/system/mysqld${MYSQL_PORT}.service <<EOF
[Unit]
Description=MySQL Server
Documentation=man:mysqld(8)
Documentation=http://dev.mysql.com/doc/refman/en/using-systemd.html
After=network.target
After=syslog.target

[Install]
WantedBy=multi-user.target

[Service]
User=mysql
Group=mysql

# Have mysqld write its state to the systemd notify socket
Type=notify

# Disable service start and stop timeout logic of systemd for mysqld service.
TimeoutSec=0

ExecStart=$BASE_DIR/bin/mysqld --defaults-file=$MYCNF_DIR \$MYSQLD_OPTS 

# Use this to switch malloc implementation
EnvironmentFile=-/etc/sysconfig/mysql

# Sets open_files_limit
LimitNOFILE = 65535

Restart=on-failure

RestartPreventExitStatus=1

# Set environment variable MYSQLD_PARENT_PID. This is required for restart.
Environment=MYSQLD_PARENT_PID=1

PrivateTmp=false
EOF
elif [[ $MYSQL_VERSION = "5.7" ]];then
cat > /usr/lib/systemd/system/mysqld${MYSQL_PORT}.service <<EOF
[Unit]
Description=MySQL Server
Documentation=man:mysqld(7)
Documentation=http://dev.mysql.com/doc/refman/en/using-systemd.html
After=network.target
After=syslog.target

[Install]
WantedBy=multi-user.target

[Service]
User=mysql
Group=mysql

Type=forking

PIDFile=$PID_FILE

# Disable service start and stop timeout logic of systemd for mysqld service.
TimeoutSec=0

# Start main service
ExecStart=$BASE_DIR/bin/mysqld --defaults-file=$MYCNF_DIR --daemonize  --pid-file=$PID_FILE \$MYSQLD_OPTS 

# Use this to switch malloc implementation
EnvironmentFile=-/etc/sysconfig/mysql

# Sets open_files_limit
LimitNOFILE = 5000

Restart=on-failure

RestartPreventExitStatus=1

PrivateTmp=false
EOF
else
  print_error "参数 MYSQL_VERSION 输入格式不正确，请输入 [8.0/5.7] "
fi
chmod 644 /usr/lib/systemd/system/mysqld${MYSQL_PORT}.service
} 

systemctl_reload(){
  print_info "执行 systemctl daemon-reload..."
  systemctl daemon-reload 
}

create_tmp_sock(){
  print_info "创建 /tmp/mysql.sock 软链"
  if [ ! -f /tmp/mysql.sock ] && [ ! -L /tmp/mysql.sock ];then
    ln -s $SOCKET_DIR /tmp/mysql.sock
    print_info "软链 /tmp/mysql.sock 创建完成"
  else
    print_warning "/tmp/mysql.sock 已存在,请确认,使用指定socket登陆请使用 -S $SOCKET_DIR 登陆"
  fi
}

## 初始化MySQL用户，修改初始密码
change_init_password(){
    ## 初始化密码 
    local TEMP_PASWORD=`cat $DATA_DIR/error.log |grep 'A temporary password'|awk -F " " '{print $(NF)}'`
    $BASE_DIR/bin/mysqladmin -uroot -p"$TEMP_PASWORD" -P$MYSQL_PORT -S $SOCKET_DIR password "${INIT_PASSWORD}" 2>/dev/null
    print_info "修改初始密码成功"
}


# 创建管理用户,当部署为slave模式不创建
create_manager_user(){
  local CHK_RESULT=$(echo "${MYCNF_TEMPLATE##*.}")
  if [ "$CHK_RESULT" != "slave" ];then
    print_info "创建超级用户['$SUPER_USER']..."
    $BASE_DIR/bin/mysql -uroot -p"${INIT_PASSWORD}" -P$MYSQL_PORT -S $SOCKET_DIR -e "create user '$SUPER_USER' identified by '${SUPER_PASSWORD}';grant all on *.* to '$SUPER_USER' with grant option;" 2>/dev/null
    print_info "用户['$SUPER_USER'@'%']创建完成"
    print_info "创建复制用户['$REPL_USER'@'%']..."
    $BASE_DIR/bin/mysql -uroot -p"${INIT_PASSWORD}" -P$MYSQL_PORT -S $SOCKET_DIR -e "create user '$REPL_USER' identified by '${REPL_PASSWORD}';GRANT Replication client,Replication slave ON *.* TO '${REPL_USER}'@'%';" 2>/dev/null
    print_info "用户['$REPL_USER'@'%']创建完成"
    print_info "创建系统管理用户['$SYS_MANAGER_USER']..."
    if [[ $MYSQL_VERSION = "8.0" ]];then
      $BASE_DIR/bin/mysql -uroot -p"${INIT_PASSWORD}" -P$MYSQL_PORT -S $SOCKET_DIR -e "create user '$SYS_MANAGER_USER'@'127.0.0.1' identified by '${SYS_MANAGER_PWD}';
      GRANT SUPER,BACKUP_ADMIN, PROCESS, RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO '$SYS_MANAGER_USER'@'127.0.0.1';
      grant all on mysql.slow_log_bak to '$SYS_MANAGER_USER'@'127.0.0.1';
      grant all on mysql.slow_log to '$SYS_MANAGER_USER'@'127.0.0.1';
      grant all on mysql.slow_log_new to '$SYS_MANAGER_USER'@'127.0.0.1';
      grant select on performance_schema.* to '$SYS_MANAGER_USER'@'127.0.0.1';" 2>/dev/null
    else
      $BASE_DIR/bin/mysql -uroot -p"${INIT_PASSWORD}" -P$MYSQL_PORT -S $SOCKET_DIR -e "create user '$SYS_MANAGER_USER'@'127.0.0.1' identified by '${SYS_MANAGER_PWD}';
      GRANT SYSTEM_VARIABLES_ADMIN,RELOAD, LOCK TABLES, PROCESS, REPLICATION CLIENT ON *.* TO '$SYS_MANAGER_USER'@'127.0.0.1';
      grant all on mysql.slow_log to '$SYS_MANAGER_USER'@'127.0.0.1';
      grant all on mysql.slow_log_new to '$SYS_MANAGER_USER'@'127.0.0.1';
      grant select on performance_schema.* to '$SYS_MANAGER_USER'@'127.0.0.1';" 2>/dev/null
    fi
      print_info "用户['$SYS_MANAGER_USER'@'127.0.0.1']创建完成"
  else 
    print_info "当前实例为从库，跳过创建管理用户..."
  fi
}

# 配置慢日志轮询
function set_rotate_slow_log(){
   $CURRENT_DIR/slow_log_rotate.sh addcron
}

# 设置开机自启动
function set_systemctl_enable(){
  systemctl enable mysqld${MYSQL_PORT}
}

# 安装
install_mysql(){
  print_info "设置系统相关"
  fix_system_config

  print_info "执行安装前检查..."
  before_install_check

  print_info "检查并安装依赖包..."
  install_dependency_packages

  #print_info "安装内存管理jemalloc,使MySQL使用jemalloc管理内存"
  #do_set_Jemalloc

  print_info "卸载 mariadb..."
  uninstall_mariadb

  print_info "解压安装包"
  uncompress_pkg

  print_info "检查并创建用户组和用户"
  create_mysql_group_and_user

  print_info "创建并授权目录"
  mkdir -p $DATA_DIR
  chown -R mysql:mysql $DATA_DIR
  chmod 750 $DATA_DIR

  print_info "设置MySQL环境变量"
  set_mysql_env

  ## 配置my.cnf
  print_info "配置my.cnf"
  set_my_cnf


  ## 初始化
  cd $BASE_DIR
  print_info "初始化MySQL..."
  bin/mysqld --defaults-file=$MYCNF_DIR --initialize  --user=mysql
  if [ $? -ne 0 ]; then
    if [ -f $DATA_DIR/error.log ];then
      tail -100 $DATA_DIR/error.log
    fi
    print_error "初始化失败，请查看错误日志！"
    exit 1
  fi

  ## 设置service 启动
  #cd $BASE_DIR
  #cp support-files/mysql.server /etc/init.d/mysqld
  print_info "配置systemd启停脚本..."
  add_systemd_mysql
  systemctl_reload

  ## 启动
  print_info "启动MySQL..."
  #$BASE_DIR/bin/mysqld_safe --defaults-file=$MYCNF_DIR --user=mysql > /dev/null &
  systemctl start mysqld${MYSQL_PORT}.service
  sleep 5
  MYSQL_STATUS=`systemctl status mysqld${MYSQL_PORT}.service |grep "active (running)"|wc -l`
  if [ $MYSQL_STATUS -gt 0 ];then
    create_tmp_sock
    print_info "\033[43m 请执行 source /etc/profile.d/mysql_set_env.sh 使环境变量生效 或 重新打开shell窗口 \033[0m"
    print_info "安装完成，MySQL已启动...   可使用 ${__BGREEN}systemctl status mysqld${MYSQL_PORT}.service${__CEND} 进行查看状态 "
  else
    print_error "启动判断异常，错误日志路径：$DATA_DIR/error.log，错误信息如下："
    tail -100 $DATA_DIR/error.log
    exit 1
  fi

  print_info "修改MySQL初始化密码..."
  change_init_password

  print_info "创建管理用户..."
  create_manager_user

  print_info "配置慢日志轮询 crontab..."
  set_rotate_slow_log

  print_info "设置开机自启【systemctl enable mysqld${MYSQL_PORT}】..."
  set_systemctl_enable
  
  print_info "MySQL 安装完成..."
}

function useage(){
  printf "Usage: ${__CCYAN}单独部署的master/slave,默认开启read_only参数的，需要自行配置read_only与复制rpl_semi_sync_replica_enabled开关${__CEND}
    $0 [./template/[5.7/8.0]/my.cnf.single]                             部署单机节点 
    $0 [./template/[5.7/8.0]/my.cnf.master]                             部署master节点
    $0 [./template/[5.7/8.0]/my.cnf.slave]                              部署slave节点,不会自动建立主从
"
  exit 1
}

function main(){
  if [ -n "$1" ];then
    # 传入或设置默认配置文件
    MYCNF_TEMPLATE=${1-"$PARENT_DIR/conf/template/${MYSQL_VERSION}/my.cnf.single"}
    install_mysql
  else 
    useage
  fi
}

main $1

