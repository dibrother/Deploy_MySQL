#!/bin/bash

CURRENT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )
PARENT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." >/dev/null 2>&1 && pwd )

source $CURRENT_DIR/print_log.sh

# 定义一个函数来执行SSH命令
# 调用方式：ssh_expect <USER> <PASS> <IP> <PORT> <CMD>
function ssh_expect {
USER=$1
PASSWORD=$2
IP=$3
PORT=$4
CMD=$5

/usr/bin/expect <<-EOF

set time 30
spawn ssh $USER@$IP $CMD
expect {
"*yes/no" { send "yes\r"; exp_continue }
"*password:" { send "$PASSWORD\r" }
}
expect eof
EOF
}

# 检测包并返回包管理名称
detect_package_manager() {
    if command -v yum &> /dev/null; then
        echo "yum"
    elif command -v apt-get &> /dev/null; then
        echo "apt-get"
    else
        echo "none"
    fi
}

# 检查端口是否被占用
function check_port_exists_to_err(){
  local port=$1
  local check_value=$(ss -tu | grep -w ${port}|wc -l)
  if [ $check_value -gt 0 ];then
    print_error "端口 [$port] 已被占用,可执行 ss -tu 检查."
    exit 1
  fi
}

# 检查文件,传入绝对路径，文件不存在则报错
function check_file_not_exists_to_err(){
    local file_path=$1 
    if [[ ! -f ${file_path} ]]; then
        print_error "${file_path} does not exists!" 
        exit 1
    fi
}

# 检查包
function check_and_install_pkg(){
   local pkg_name=$1
   local package_manager=$(detect_package_manager)
   if [ $package_manager = "yum" ];then
    local chk_result=$(rpm -qa|grep $pkg_name|wc -l)
   else
    local chk_result=$(dpkg -l |grep $pkg_name|wc -l)
   fi

   if [ $chk_result -eq 0 ];then
      print_warning "未检测到已安装包 $pkg_name..."
      $package_manager install -y $1
   fi
}

# 检查文件,传入绝对路径，文件存在则报错
function check_file_already_exists_to_err(){
    local FILE_PATH=$1 
    if [[ -f ${FILE_PATH} ]]; then
        print_error "${FILE_PATH} already exists!" 
        exit 1
    fi
}

# 检查文件夹是否为空，不为空则报错
function check_dir_not_empty_to_err(){
    local dir=$1 
    if [ -d $dir ];then
      if [ "$(ls -A $dir)" ];then
        print_error "目录$dir 已存在且不为空！"
        exit 1
      fi
    fi
}


# 检查是否传入IP是否在当前服务器上存在,不存在则抛出异常
function check_ip_not_exists_on_localserver_to_err(){
  local IP=$1
  local CHK_RESULT=$(ip -4 a|grep -w ${IP}|wc -l)
  if [ ${CHK_RESULT} -eq 0 ];then
    print_error "传入IP 与当前服务器IP不匹配，请检查配置文件中的IPADDR设置."
    exit 1
  fi
}

# 检查是否传入IP是否在当前服务器上存在,存在返回Y 不存在返回 N
function check_ip_exists_on_localserver(){
  local IP=$1
  local CHK_RESULT=$(ip -4 a|grep -w ${IP}|wc -l)
  if [ ${CHK_RESULT} -eq 0 ];then
    echo "N"
  else
    echo "Y"
  fi
}

# 检查能否上外网
function check_internet_connection(){
  # 尝试 ping 公共 DNS 服务器
  ping -c 1 -W 3 8.8.8.8 > /dev/null 2>&1

  # 检查 ping 命令的退出状态
  if [ $? -eq 0 ]; then
      echo "Y"
  else
      echo "N"
  fi
}

############################## 系统相关 ##############################
# 检查是否使用CPU节能策略
function check_cpupower(){
    local package_manager=$(detect_package_manager)
    if [ $package_manager = "yum" ];then
      local chk_result=$(cpupower frequency-info --policy|grep powersave|wc -l)
      if [ $chk_result -gt 0 ];then
          print_error "CPU节能策略开启，请先设置关闭！！"
          exit 1
      fi
    elif [ $package_manager = "apt-get" ];then
      apt-get install -y cpufrequtils
      local chk_result=$(cpufreq-info | grep -i active|grep -Ei "powersave|ondemand"|wc -l)
      if [ $chk_result -gt 0 ];then
          print_error "CPU节能策略开启，请先设置关闭！！"
          exit 1
      fi
    fi
}

# 外网连通性检测
function check_connect_external(){
  local TARGET_HOST='223.6.6.6'
  ping -c 1 -W 1 "$TARGET_HOST" > /dev/null
  # 检查 ping 命令的退出状态
  if [ $? -eq 0 ]; then
    #echo "已连接到外部互联网."
    return 0
  else
    #echo "无法连接到外部互联网."
    return 1
  fi
}

# 检查是否配置时间同步
check_ntp_status() {
  local ntpd_status=0
  local chronyd_status=0
  if ! systemctl is-active ntpd &> /dev/null; then
      ntpd_status=1
  fi

  # 检查 chrony 是否已安装
  if ! systemctl is-active chronyd &> /dev/null; then
      chronyd_status=1
  fi

  if [[ $chronyd_status -eq 0 ]] || [[ $ntpd_status -eq 0 ]]; then
    print_info "检测到已配置时间同步..."
  else
    print_error "未配置时间同步,请先配置时间同步!"
    exit 1
  fi
}

# 关闭防火墙
function do_stop_firewalld(){
  if [ $package_manager = "apt-get" ];then
    print_warning "Debian或Ubuntu系列系统请自行关闭防火墙..."
  else
    systemctl stop firewalld
    systemctl disable firewalld
  fi
}

# 关闭 selinux
function do_disable_selinux(){
  if [ -f "/etc/selinux/config" ]; then
    sed -i 's#SELINUX=enforcing#SELINUX=disabled#g' /etc/selinux/config
    local chk_result=$(getenforce)
    if [ $chk_result != "Disabled" ];then      
      setenforce 0
    fi
  else
    print_info "当前服务器未启用 selinux."
  fi
}

# 关闭 swap
function do_swapoff(){
  local chk_result=$(cat /etc/sysctl.conf|grep "vm.swappiness = 0"|wc -l)
  if [ $chk_result -eq 0 ];then
    print_warning "设置 swap 值为 0，关闭swap. "
    echo "vm.swappiness = 0">> /etc/sysctl.conf
    swapoff -a && swapon -a
    sysctl -p
  fi
}

# 设置 swap = 1
function do_swap_to_one() {
    local chk_result=$(grep -c "^vm\.swappiness" /etc/sysctl.conf)

    if [[ $chk_result -eq 0 ]]; then
        print_warning "设置 swap 值为 1."
        sysctl vm.swappiness=1
        echo "vm.swappiness = 1" >> /etc/sysctl.conf
        sysctl -p
    else
        local chk_result=$(grep -c "^vm\.swappiness=1" /etc/sysctl.conf)
        if [[ $chk_result -eq 0 ]]; then
          sed -i 's/^vm\.swappiness.*/vm.swappiness=1/' /etc/sysctl.conf
          sysctl -p
        fi
    fi
}

# 优化内核参数
function do_optimize_kernel_parameters() {
    local CHK_RESULT=$(cat /etc/sysctl.conf|egrep "vm.swappiness|fs.file-max|net.core.rmem_max|net.ipv4.conf.lo.arp_announce|net.core.somaxconn"|wc -l)
    if [ $CHK_RESULT -lt 5 ];then
        local timestamp=`date +%F-%T`
        mv /etc/sysctl.conf /etc/sysctl.conf.bak-$timestamp
    cat >> /etc/sysctl.conf << EOF
fs.file-max = 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_max_tw_buckets = 55000
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 1100 65535
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 200000
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 2097152
net.core.wmem_max = 2097152
# 路由转发
net.ipv4.ip_forward = 1
# 开启反向路径过滤
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.arp_announce = 2
net.ipv4.conf.lo.arp_announce=2
net.ipv4.conf.all.arp_announce=2
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syncookies = 0
net.ipv4.tcp_syncookies = 1
vm.swappiness = 0
kernel.sysrq = 1
vm.max_map_count = 262144
fs.inotify.max_user_instances = 8192
#net.netfilter.nf_conntrack_max = 524288
EOF
    # 立即生效
    sysctl -p

    echo "DefaultLimitNOFILE=65535" >> /etc/systemd/system.conf
    systemctl daemon-reload
    print_warning "已优化内核参数..."
  fi
}

# 修改使用资源上限
function do_optimize_resource_limits(){
  local CHECK_RESULT=$(cat /etc/security/limits.conf |grep root|grep 65535|wc -l)
  if [ $CHECK_RESULT -lt 2 ];then
  cat >> /etc/security/limits.conf <<EOF
* soft nproc 65535
* hard nproc 65535
root soft nofile 65535
root hard nofile 65535
* soft nofile 65535
* hard nofile 65535
EOF

ulimit -n 65536
ulimit -u 65536
print_warning "已优化资源使用上限..."
  fi
}

# 采用Jemalloc代替glibc自带的malloc库
function do_set_Jemalloc(){
    if [ ! -f "/etc/sysconfig/mysql" ];then
      local package_manager=$(detect_package_manager)
      if [ $package_manager = "yum" ];then
        yum install -y jemalloc jemalloc-devel
        echo "LD_PRELOAD=/usr/lib64/libjemalloc.so" >> /etc/sysconfig/mysql
        echo "THP_SETTING=never" >> /etc/sysconfig/mysql
        chk_result=$(ls -la /usr/lib64/libjemalloc.so*|wc -l)
        if [ $chk_result -gt 0 ];then
            print_info "jemalloc 安装完成。"
        else
            print_error "安装 jemalloc 异常，请检查!"
            exit 1
        fi
      else
        apt-get install -y libjemalloc2
      fi
    else
        print_info "jemalloc 已被安装..."
    fi
}

# 检查内核
function check_kernel(){
    local kernel_name=$(uname -s)
    if [[ "${kernel_name}" == "Linux" ]]; then
        print_info "kernel = ${kernel_name}"
        return 0
    else
        print_error "kernel = ${kernel_name}, not supported, Linux only"
        exit 1
    fi
}
