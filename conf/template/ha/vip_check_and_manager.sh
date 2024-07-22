#!/bin/bash
set -e

## 判断 replication-manager 是否正常启动，如果没有启动则不做任何操作
## 判断 replication-manager 是否处于切换或故障恢复阶段
## 判断是否非 Master，如果非 Master 继续判断是否存在 VIP ，如果存在 VIP 则卸载
## 判断是否为 Master，如果为 Master ,则执行添加 VIP 操作

CURRENT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )
PARENT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." >/dev/null 2>&1 && pwd )
ha_http_user=admin


# 根据环境配置
# 网卡名称、VIP、ssh端口、ssh用户
interface=eth0
vip=10.10.2.111
ssh_options="-p22"
ssh_user='root'

# MySQL的端口、ha组件的用户名、密码
mysql_port=3306
ha_http_password=repman

ssh=$(which ssh)
arping=$(which arping)
ip2util=$(which ip)
replication_cli=$(which replication-manager-cli)

cmd_vip_add="$ip2util address add ${vip} dev ${interface}"
cmd_vip_del="$ip2util address del ${vip}/32 dev ${interface}"
cmd_vip_chk="$ip2util address show dev ${interface} to ${vip%/*}/32"
cmd_arp_fix="$arping -c 1 -I ${interface} ${vip%/*}"
cmd_local_arp_fix="$arping -c 1 ${vip%/*}"


# 输出打印
__CEND='\033[0m';
__CRED='\033[0;31m';
__CGREEN='\033[0;32m';
__CYELLOW='\033[0;33m';

print_info(){
    echo -e "$(date +"%Y-%m-%d %H:%M:%S") ${__CGREEN}[INFO]${__CEND} $1"
}

print_warning(){
    echo -e "$(date +"%Y-%m-%d %H:%M:%S") ${__CYELLOW}[WARNING]${__CEND} $1"
}

print_error(){
    echo -e "$(date +"%Y-%m-%d %H:%M:%S") ${__CRED}[ERROR]${__CEND} $1"
}

# arping 检查，被占用返回1，未占用返回0
vip_arping_check(){
    if $arping -c 1 -I ${interface} ${vip%/*} > /dev/null 2>&1; then
        return 1
    else
        return 0
    fi
}

vip_start() {
    local host_ip=$1
    rc=0

    # ensure the vip is added
    # this command should exit with failure if we are unable to add the vip
    # if the vip already exists always exit 0 (whether or not we added it)

    if vip_arping_check;then
        $ssh ${ssh_options} -tt ${ssh_user}@${host_ip} \
        "[ -z \"\$(${cmd_vip_chk})\" ] && ${cmd_vip_add} && ${cmd_arp_fix} || [ -n \"\$(${cmd_vip_chk})\" ]"
        rc=$?
    else
        print_error "Can't add $vip,vip is already be used!" 
        rc=1
    fi
    return $rc
}

vip_stop() {
    local host_ip=$1
    rc=0

    # ensure the vip is removed
    $ssh ${ssh_options} -tt ${ssh_user}@${host_ip} \
    "[ -n \"\$(${cmd_vip_chk})\" ] && ${cmd_vip_del} && sudo ${ip2util} route flush cache || [ -z \"\$(${cmd_vip_chk})\" ]"
    rc=$?
    return $rc
}

# 检查 vip 是否已存在,返回 0-不存在，1-存在
# 检查 vip 是否已存在,返回 0-不存在，1-存在
function check_vip_exists(){
  local host_ip=$1
  local rc=0
  # 使用 SSH 执行远程命令检查 VIP 是否存在，使用 grep 的 -q 选项来静默模式检查
  if $ssh ${ssh_options} -tt ${ssh_user}@${host_ip} "$ip2util a | grep -qi $vip/32" > /dev/null 2>&1; then
    rc=1
  else
    rc=0
  fi
  # 返回状态码
  return $rc
}

# 判断replication manager 状态，没有启动则退出
function check_replication_active_status(){
  replication_status=$(systemctl is-active replication-manager.service)
  if [ "$status" != "active" ]; then
    print_warning "replication manager 没有启动，不执行任何操作，退出."
    exit 0
  fi
}

# 检查 replication-manager 是否处于切换或故障恢复阶段
function vip_manager_with_replication_manager(){
  if [[ -z "$replication_cli" ]];then
    print_error "不存在 replication-manager-cli  ,请检查是否已安装 replication-manager !"
    exit 1
  fi

  if [ "$(systemctl is-active replication-manager.service)" = "inactive" ];then
    print_error " replication-manager 状态异常，不执行任何操作，退出."
  else
    # 获取 topology
    local topology=$($replication_cli --user=${ha_http_user} --password=${ha_http_password} --port=10005 topology)
    
    ########### 检查是否处于failover切换状态，如果是则不做任何操作退出 ################
    local suspect_count=$(echo "$topology"|grep Suspect|wc -l)
    if [[ "$suspect_count" -eq 1 ]];then
      print_warning "当前正处于执行 failover 状态，不做任何操作，退出."
      exit 0
    fi

    # 获取状态为 Master 的ip
    local master_ip=$(echo "$topology"|grep Master|awk -F ' ' '{print $2}')
    # 获取状态为非 Master 的 ip
    not_masters=$(echo "$topology"|grep ${mysql_port}|grep -v Master|awk -F ' ' '{print $2}')
    not_masters_arr=($not_masters)
    # 遍历非主库，若存在 VIP 则卸载
    for ip in "${not_masters_arr[@]}"; do
      #echo "---- 正在处理的IP: $ip"
      if ! check_vip_exists ${ip};then
        print_warning "[异常] VIP 存在与非主服务器上,需执行卸载.."
        if vip_stop ${ip}; then
          print_warning "VIP 已在[$ip]上删除"
        else
          print_error "VIP 删除失败,请检查!"
        fi
      fi
    done
    
    # 计算输出中的行数
    local line_count=$(echo "$master_ip" | wc -l)
    # 检查行数是否为1,如果为1则正常，如果有多个Master,可能正处于 switchover 状态 
    if [ "$line_count" -gt 1 ]; then
      print_warning "当前状态存在[$line_count]个Master[$master_ip],可能正处于switchover切换状态，不做任何操作,退出."
      exit 0
    fi

    # 检查行数是否为1,如果为1则正常，如果有多个Master,可能正处于 switchover 状态 
    if [ "$line_count" -eq 1 ]; then
      if check_vip_exists ${master_ip};then
        print_warning "检测到当前存在Master[$master_ip],且Master上不存在vip[${VIP}]..."
        print_warning "执行添加 vip 操作..."
        if vip_start ${master_ip}; then
          print_info "VIP[${VIP}] 已在[$master_ip]上添加"
          exit 0
        else
          print_error "VIP[${VIP}] 添加失败,请检查!"
          exit 1
        fi
      fi
    else
      print_warning "当前状态存在[$line_count]个Master[$master_ip],可能正处于切换状态，不做任何操作."
      exit 0
    fi
  fi
}

vip_manager_with_replication_manager
