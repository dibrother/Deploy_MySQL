#!/bin/bash

# 当前脚本适用于中间件为 replication-manager 的高可用VIP切换,
# 接收传入参数 cluster.oldMaster.Host cluster.master.Host cluster.oldMaster.Port cluster.master.Port
orig_master=$1
new_master=$2
old_port=$3
new_port=$4

#mysql_user='ha_monitor'
#mysql_password='yq@ABC^123#forha'

emailaddress="email@example.com"
sendmail=0

# 根据环境配置
# 网卡名称
interface=eth0
# VIP
vip=10.10.2.100
# ssh用户
ssh_options='-p22'
ssh_user='root'


# discover commands from our path
ssh=$(which ssh)
arping=$(which arping)
ip2util=$(which ip)

# command for adding our vip
# cmd_vip_add="sudo -n $ip2util address add ${vip} dev ${interface}"
cmd_vip_add="$ip2util address add ${vip} dev ${interface}"
# command for deleting our vip
#cmd_vip_del="sudo -n $ip2util address del ${vip}/32 dev ${interface}"
cmd_vip_del="$ip2util address del ${vip}/32 dev ${interface}"
# command for discovering if our vip is enabled
#cmd_vip_chk="sudo -n $ip2util address show dev ${interface} to ${vip%/*}/32"
cmd_vip_chk="$ip2util address show dev ${interface} to ${vip%/*}/32"
# command for sending gratuitous arp to announce ip move
#cmd_arp_fix="sudo -n $arping -c 1 -I ${interface} ${vip%/*}"
cmd_arp_fix="$arping -c 1 -I ${interface} ${vip%/*}"
# command for sending gratuitous arp to announce ip move on current server
#cmd_local_arp_fix="sudo -n $arping -c 1 ${vip%/*}"
cmd_local_arp_fix="$arping -c 1 ${vip%/*}"

SCRIPT_DIR=$(cd `dirname $0`; pwd)
########################  dingding通知配置[可选修改]  ##########################
DINGDING_SWITCH=0
MSG_TITLE='数据库切换告警'
WEBHOOK_URL='https://oapi.dingtalk.com/robot/send?access_token=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
SECRET='SECxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
# 支持 text/markdown
SEND_TYPE='markdown'
# IS_AT_ALL 中设置任何值代表执行 true ,默认为false
IS_AT_ALL=''
# 设置电话号码会@那个人,这个设置值的话 -at_all 参数不能配置"
AT_MOBILES=''

## 打印
print_message(){
  TAG=$1
  MSG=$2
  if [[ $1 = "Error" ]];then
    echo -e "`date +'%F %T'` [\033[31m$TAG\033[0m] $MSG"
  elif [[ $1 = "Warning" ]];then
    echo -e "`date +'%F %T'` [\033[34m$TAG\033[0m] $MSG"
  else
    echo -e "`date +'%F %T'` [\033[32m$TAG\033[0m] $MSG"
  fi
}

# 钉钉信息发送
## $1 通知/异常
## $2 发送信息
dingding_note(){
  if [[ ${DINGDING_SWITCH} -eq 1 ]];then
    print_message "通知" "发送钉钉通知..."
    if [[ $1 == "通知" ]]; then
      local color="#006600"
    else
      local color="#FF0033"
    fi
    local DING_MESSAGE="**[<font color=${color}>$1</font>]** \n \n--- \n$2"
    if [[ ${IS_AT_ALL} ]];then
      DING_STATUS=`${SCRIPT_DIR}/dingtalk_send -url "${WEBHOOK_URL}" -secert "${SECRET}" -title "${MSG_TITLE}" -type "${SEND_TYPE}" -msg "${DING_MESSAGE}" -at_all`
    elif [[ ${AT_MOBILES} ]];then
     DING_STATUS=`${SCRIPT_DIR}/dingtalk_send -url "${WEBHOOK_URL}" -secert "${SECRET}" -title "${MSG_TITLE}" -type "${SEND_TYPE}" -msg "${DING_MESSAGE}" -at_mobiles ${AT_MOBILES}`
    else
      #echo "${SCRIPT_DIR}/dingtalk_send -url \"${WEBHOOK_URL}\" -secert \"${SECRET}\" -title \"${MSG_TITLE}\" -type \"${SEND_TYPE}\" -msg \"${DING_MESSAGE}\""
      DING_STATUS=`${SCRIPT_DIR}/dingtalk_send -url "${WEBHOOK_URL}" -secert "${SECRET}" -title "${MSG_TITLE}" -type "${SEND_TYPE}" -msg "${DING_MESSAGE}"`
    fi
    if [ "${DING_STATUS}" = '{"errcode":0,"errmsg":"ok"}' ];then
      print_message "Note" "钉钉消息发送成功"
    else
      print_message "Error" "钉钉消息发送失败,请检查! 钉钉命令为 dingding_note \"通知\" \"${DING_MSG}\""
      #exit 1
    fi
    print_message "通知" "钉钉通知完成..."
  fi
}

vip_start() {
    rc=0

    # ensure the vip is added
    # this command should exit with failure if we are unable to add the vip
    # if the vip already exists always exit 0 (whether or not we added it)

    if vip_arping_check;then
        $ssh ${ssh_options} -tt ${ssh_user}@${new_master} \
        "[ -z \"\$(${cmd_vip_chk})\" ] && ${cmd_vip_add} && ${cmd_arp_fix} || [ -n \"\$(${cmd_vip_chk})\" ]"
        rc=$?
    else
        print_error "Can't add $vip,vip is already be used!" 
        rc=1
    fi
    return $rc
}

vip_status() {
    $arping -c 1 -I ${interface} ${vip%/*}
    if ping -c 1 -W 1 "$vip"; then
        return 0
    else
        return 1
    fi
}

# arping 检查，被占用返回1，未占用返回0
vip_arping_check(){
    if $arping -c 1 -I ${interface} ${vip%/*} > /dev/null 2>&1; then
        return 1
    else
        return 0
    fi
}

change_master_params(){
  mysql_version=`/usr/local/mysql/bin/mysql -h${new_master} -u${mysql_user} -p${mysql_password} -P${new_port} -Ne "select version()"` 
  if [[ ${mysql_version} > "8.0.25" ]];then
     echo "设置主参数为 read_only=0;super_read_only=0;rpl_semi_sync_source_enabled=1;rpl_semi_sync_replica_enabled=0;"
    /usr/local/mysql/bin/mysql -h${new_master} -u${mysql_user} -p${mysql_password} -P${new_port} -e "set global read_only=0;set global super_read_only=0;set global rpl_semi_sync_source_enabled=1;set global rpl_semi_sync_replica_enabled=0;"
  else
    echo "设置主参数为 read_only=0;super_read_only=0;rpl_semi_sync_master_enabled=1;rpl_semi_sync_slave_enabled=0;"
    /usr/local/mysql/bin/mysql -h${new_master} -u${mysql_user} -p${mysql_password} -P${new_port} -e "set global read_only=0;set global super_read_only=0;set global rpl_semi_sync_master_enabled=1;set global rpl_semi_sync_slave_enabled=0;"
  fi
  print_message "通知" "修改主从参数完成."
}

change_orig_master_params(){
  MYSQL_STATUS=`/usr/local/mysql/bin/mysqladmin -h${orig_master} -u${mysql_user} -p${mysql_password} -P${old_port} ping|grep 'mysqld is alive'|wc -l`
  #echo "/usr/local/mysql/bin/mysqladmin -h${orig_master} -u${mysql_user} -p${mysql_password} -P${old_port} ping|grep 'mysqld is alive'|wc -l"
  if [ ${MYSQL_STATUS} -eq 1 ];then
    echo "源库存活,则修改源库参数为只读,且修改半同步参数..."
    mysql_version=`/usr/local/mysql/bin/mysql -h${orig_master} -u${mysql_user} -p${mysql_password} -P${old_port} -Ne "select version()"`
    if [[ ${mysql_version} > "8.0.25" ]];then
      #echo "源库存活,则修改源库参数为只读,且修改半同步参数..."
      /usr/local/mysql/bin/mysql -h${orig_master} -u${mysql_user} -p${mysql_password} -P${old_port} -e "set global read_only=1;set global super_read_only=1;set global rpl_semi_sync_source_enabled=0;set global rpl_semi_sync_replica_enabled=1;"
    else
      #echo "源库存活,则修改源库参数为只读,且修改半同步参数..."
      /usr/local/mysql/bin/mysql -h${orig_master} -u${mysql_user} -p${mysql_password} -P${old_port} -e "set global read_only=1;set global super_read_only=1;set global rpl_semi_sync_master_enabled=0;set global rpl_semi_sync_slave_enabled=1;"   
    fi
  fi
}


print_message "Note" "make vip up on new master..."
if vip_start; then
      print_message "Note" "$vip is moved to $new_master."
      #change_master_params
      #change_orig_master_params
      SEND_MSG="**异常信息:** 发生主从切换\n* 原主服务器: ${orig_master}:${old_port}\n* 新主服务器: $new_master:$new_port\n* 主从切换成功。\n---\n**通知时间:** \n \n`date '+%Y-%m-%d %H:%M:%S'`"
      dingding_note "数据库切换" "$SEND_MSG"
      #echo "`date +'%Y-%m-%d %T'` $vip is moved to $new_master."
      #if [ $sendmail -eq 1 ]; then mail -s "$vip is moved to $new_master." "$emailaddress" < /dev/null &> /dev/null  ; fi

else
      print_message "Note" "Can't add $vip on $new_master!"
      SEND_MSG="**异常信息:** 添加VIP失败\n* 原主服务器: ${orig_master}:${old_port}\n* 新主服务器: $new_master:$new_port\n* 异常信息: Can't add $vip on $new_master!\n---\n**通知时间:** \n \n`date '+%Y-%m-%d %H:%M:%S'`"
      dingding_note "异常" "$SEND_MSG"
      #echo "`date +'%Y-%m-%d %T'` Can't add $vip on $new_master!"
      #if [ $sendmail -eq 1 ]; then mail -s "Can't add $vip on $new_master!" "$emailaddress" < /dev/null &> /dev/null  ; fi
      exit 1
fi
