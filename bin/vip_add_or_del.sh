#!/bin/bash
set -e

CURRENT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )
PARENT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." >/dev/null 2>&1 && pwd )

# 加载配置文件
source $CURRENT_DIR/mysql.sh


# 根据环境配置
# 网卡名称
interface=$NET_WORK_CARD_NAME
# VIP
vip=$VIP
# ssh用户
ssh_options="-p${SERVER_PORT}"
ssh_user='root'


ssh=$(which ssh)
arping=$(which arping)
ip2util=$(which ip)

cmd_vip_add="$ip2util address add ${vip} dev ${interface}"
cmd_vip_del="$ip2util address del ${vip}/32 dev ${interface}"
cmd_vip_chk="$ip2util address show dev ${interface} to ${vip%/*}/32"
cmd_arp_fix="$arping -c 1 -I ${interface} ${vip%/*}"
cmd_local_arp_fix="$arping -c 1 ${vip%/*}"

# arping 检查，被占用返回1，未占用返回0
vip_arping_check(){
    if $arping -c 1 -I ${interface} ${vip%/*} > /dev/null 2>&1; then
        return 1
    else
        return 0
    fi
}

vip_start() {
    rc=0

    # ensure the vip is added
    # this command should exit with failure if we are unable to add the vip
    # if the vip already exists always exit 0 (whether or not we added it)

    if vip_arping_check;then
	output_of_cmd_vip_chk=$($cmd_vip_chk)
	if [[ -z "$output_of_cmd_vip_chk" ]]; then
            $($cmd_vip_add)
            rc=$?
	else
	    print_error "Can't add $vip,vip is already exists!"
	    rc=1
        fi	  
    else
        print_error "Can't add $vip,vip is already be used!"
        rc=1
    fi
    return $rc
}

vip_stop() {
    rc=0

    [ -n "$(${cmd_vip_chk})" ] && $(${cmd_vip_del}) && $(${ip2util} route flush cache) || [ -z "$(${cmd_vip_chk})" ]
    rc=$?
    return $rc
}

# useage 
function useage(){
  printf "Usage:  
    $0 add                           	添加VIP
    $0 del                             删除VIP
"
  exit 1
}

function main(){
  if [ -n "$1" ];then
    if [ $1 == "add" ];then
       if vip_start; then
         print_info "VIP 已在[$IPADDR]上添加"
       else
         print_error "VIP 添加失败,请检查!"
       fi
    elif [ $1 == "del" ];then
       local is_exists=$(ip a|grep "${vip%/*}/32"|wc -l)
       if [[ $is_exists -eq 0 ]];then
         print_warning "VIP 不存在于[$IPADDR]上"
	       exit 0
       fi
       if vip_stop; then
         print_info "VIP 已在[$IPADDR]上删除"
       else
         print_error "VIP 删除失败,请检查!"
       fi
    else
      useage
    fi
  else
    useage
  fi
}

main $1
