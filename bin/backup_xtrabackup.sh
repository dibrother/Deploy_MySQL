#!/bin/bash
#set -e
####################### 简介 ###########################3
# 作者:杨大仙
# 使用方法
# ● 修改脚本相关配置
# ● 支持本地备份、远程备份（需要对远程机做免密）、钉钉告警
# ● 可以执行  ./xtra_bak add_cron /app/scrpits/xtra_bak.sh 添加定时任务cron，默认时间点为每天凌晨2:55进行备份

# 需要创建备份用户,如:
# CREATE USER 'databak'@'127.0.0.1' IDENTIFIED BY 'Yq@BackUP!321';

# 5.7 需要权限
# GRANT RELOAD, LOCK TABLES, PROCESS, REPLICATION CLIENT ON *.* TO 'databak'@'127.0.0.1';

# 8.0 需要权限
# GRANT BACKUP_ADMIN, PROCESS, RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'databak'@'127.0.0.1';
# GRANT SELECT ON performance_schema.log_status TO 'databak'@'127.0.0.1';
# GRANT SELECT ON performance_schema.keyring_component_status TO'databak'@'127.0.0.1';
# GRANT SELECT ON performance_schema.replication_group_members TO databak@'127.0.0.1';

######################################################################################
########################  xtraback信息配置[必须根据环境修改]  ##########################
#XTRABACKUP_PATH=/usr/bin/xtrabackup
#BACKUP_SAVE_DAYS=7
#BACKUP_DIR=/data/backup
#BACKUP_PREFIX_NAME="xtra_full"
## 压缩并发进程与备份并发进程数，默认都为2
#COMPRESS_THREADS=2
#PARALLEL=2

########################  Mysql备份用户信息[必须根据环境修改]  ##########################
#MYCNF_DIR=/data/mysql3312/my3312.cnf
#SYS_MANAGER_USER=databak
#SYS_MANAGER_PWD='Yq@BackUP!321'
#MYSQL_PORT=3312
#BACKUP_HOST='127.0.0.1'
#SOCKET_DIR=/data/mysql3312/data/mysql.sock
#IPADDR=192.168.66.166

########################  远程传输配置，使用远程需要配置免密[可选修改]  ##########################
## 远程备份开关，默认0
#REMOTE_BACKUP_SWITCH=0
#REMOTE_TITLE="数据库远程备份"
#REMOTE_USER=root
#REMOTE_HOST=192.168.66.167
#REMOTE_PORT=22
#REMOTE_BACKUP_DIR=/data/backup
########################  dingding通知配置[可选修改]  ##########################
#DINGDING_SWITCH=0
#MSG_TITLE="数据库备份"
#WEBHOOK_URL='https://oapi.dingtalk.com/robot/send?access_token=exxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
#SECRET='SECxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
# 支持 text/markdown
#SEND_TYPE="markdown"
# IS_AT_ALL 中设置任何值代表执行 true ,默认为false
#IS_AT_ALL=""
# 设置电话号码会@那个人,这个设置值的话 -at_all 参数不能配置"
#AT_MOBILES=""

######################################################################################

# 获取配置文件信息,若不是使用配置文件,则将上面注释参数打开进行配置

########################  以下无需更改  ###############################
# 获取脚本绝对路径,需要与dingtaik_send在一个目录下
CURRENT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )
PARENT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." >/dev/null 2>&1 && pwd )

source $CURRENT_DIR/mysql.sh
source ${PARENT_DIR}/conf/backup/conf_xtrabackup.conf

BACKUP_HOST='127.0.0.1'


XTRABACKUP_PATH=`which xtrabackup`

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

if [ ! -d ${BACKUP_DIR} ];then
    print_message "Error" "目录${BACKUP_DIR}不存在,请确认!"
    exit 1
  else
    mkdir -p $BACKUP_DIR/log
fi
      
BACKUP_LOG=$BACKUP_DIR/log
BACKUP_DATETIME=`date +%Y%m%d%H%M%S`
LOCAL_DISK_CMD=`df -Th ${BACKUP_DIR}|awk '{print $6}'|tail -1`

# 环境检查
backup_environment_check(){
  print_message "Note" "进行备份前预检查"
	if [ ! -x ${XTRABACKUP_PATH} ];then
          print_message "Error" "xtrabackup 命令不存在，请检查！"
          exit 1 
	fi
  
  local DISK_CMD_STATUS=${LOCAL_DISK_CMD}
	if [ ! -d ${BACKUP_DIR} ]  || [ ! ${BACKUP_SAVE_DAYS} ] || [ ! ${BACKUP_PREFIX_NAME} ] || [ ! ${COMPRESS_THREADS} ]  || [ ! ${PARALLEL} ] || [ ! ${DISK_CMD_STATUS} ];then
          print_message "Error" "备份参数配置不正确，请检查！"
          exit 1
	fi
        
  if [ ! -e ${MYCNF_DIR} ]  || [ ! ${SYS_MANAGER_USER} ] || [ ! ${SYS_MANAGER_PWD} ] || [ ! ${MYSQL_PORT} ];then
          print_message "Error" "MySQL参数配置不正确，请检查！"
          exit 1
  fi

	if [ ! -d ${BACKUP_LOG} ];then
          print_message "Note" "创建日志文件目录"
          mkdir -p $BACKUP_LOG
	fi
    
        IP_IS_EXISTS=`ip -4 a|grep -w $IPADDR|wc -l`
        if [ $IP_IS_EXISTS -eq 0 ];then
          print_message "Error" "传入IP 与当前服务器IP不匹配，请检查! 传入IP为:${IPADDR}"
          exit 1
        fi

	if [ ${REMOTE_BACKUP_SWITCH} -eq 1 ];then
          if [ ! ${REMOTE_USER} ] || [ ! ${REMOTE_HOST} ] || [ ! ${REMOTE_BACKUP_DIR} ];then
            print_message "Error" "远程参数配置缺漏，请检查！"
            exit 1
          fi
	    REMOTE_DISK_USE_CMD="df -Th ${REMOTE_BACKUP_DIR}|awk '{print \$6}'|tail -1"
          # ssh 免密检查，到远程机需要配置免密
          SSH_FREE_STATUS=`ssh -p${REMOTE_PORT} ${REMOTE_HOST} -o PreferredAuthentications=publickey -o StrictHostKeyChecking=no "date" |wc -l`
          if [ $SSH_FREE_STATUS -lt 1 ];then
            print_message "Error" "免密验证[${REMOTE_HOST}]失败,请检查免密配置!"
            exit 1
          fi
          CHECK_REMOTE_BACKUP_DIR=`ssh -p${REMOTE_PORT} ${REMOTE_HOST} -o PreferredAuthentications=publickey -o StrictHostKeyChecking=no "[  -d ${REMOTE_BACKUP_DIR} ] && echo 0|| echo 1"`
	        if [ $CHECK_REMOTE_BACKUP_DIR -eq 1 ];then
	            print_message "Error" "远程备份目录 ${REMOTE_BACKUP_DIR} 不存在,请先创建!"
              exit 1
	        fi
  elif [ ${REMOTE_BACKUP_SWITCH} != 0 ];then
          print_message "Error" "REMOTE_BACKUP_SWITCH 参数请传入值 0 或 1"
          exit 1
	fi

	print_message "Note" "预检查完成"
}

# 流式压缩备份-本地 --ftwrl-wait-timeout=
xbstream_compress_backup_local(){
    local BAKUP_BEGIN_TIME=`date +"%Y-%m-%d %H:%M:%S"`
    print_message "Note" "开始进行本地备份"
    ${XTRABACKUP_PATH} --defaults-file=${MYCNF_DIR} --host=${BACKUP_HOST} --user=${SYS_MANAGER_USER} --password="${SYS_MANAGER_PWD}" --port=${MYSQL_PORT} --backup --stream=xbstream --target-dir=${BACKUP_DIR} --ftwrl-wait-timeout=300 --compress --slave-info --compress-threads=${COMPRESS_THREADS} --parallel=${PARALLEL} > ${BACKUP_DIR}/${BACKUP_PREFIX_NAME}_${BACKUP_DATETIME}.xb 2>${BACKUP_LOG}/${BACKUP_PREFIX_NAME}_${BACKUP_DATETIME}.log
    local BAKUP_END_TIME=`date +"%Y-%m-%d %H:%M:%S"` 

    check_backup_status
    
    if [[ ${DINGDING_SWITCH} -eq 1 ]];then
      local LOCAL_DISK_USE=${LOCAL_DISK_CMD}
      local BACKUP_FILE_SIZE=`ls -lh ${BACKUP_DIR}/${BACKUP_PREFIX_NAME}_${BACKUP_DATETIME}.xb|awk '{print $5}'`
      local DING_MSG="**通知内容:**\n* 执行备份服务器:${IPADDR}\n* 备份文件:${BACKUP_PREFIX_NAME}_${BACKUP_DATETIME}.xb\n* 文件大小：${BACKUP_FILE_SIZE}\n* 备份目录：${BACKUP_DIR}\n* 磁盘使用率：${LOCAL_DISK_USE}\n* 备份开始时间:${BAKUP_BEGIN_TIME}\n* 备份结束时间:${BAKUP_END_TIME}\n---\n**通知时间:** \n \n`date '+%Y-%m-%d %H:%M:%S'`"
      if [ ${BACKUP_STATUS} -eq 1 ];then
        dingding_note "通知" "${DING_MSG}"
      else
        dingding_note "异常" "${DING_MSG}"     
      fi
    fi   
    print_message "Note" "本地备份完成"
}

# 流式压缩备份-远程
xbstream_compress_backup_remote(){
    local BAKUP_BEGIN_TIME=`date +"%Y-%m-%d %H:%M:%S"`
    print_message "Note" "开始进行远程备份"
    ${XTRABACKUP_PATH} --defaults-file=${MYCNF_DIR} --host=${BACKUP_HOST} --user=${SYS_MANAGER_USER} --password="${SYS_MANAGER_PWD}" --port=${MYSQL_PORT} --backup --stream=xbstream --target-dir=${BACKUP_DIR} --ftwrl-wait-timeout=300 --compress --slave-info --compress-threads=${COMPRESS_THREADS} --parallel=${PARALLEL} 2>${BACKUP_LOG}/${BACKUP_PREFIX_NAME}_${BACKUP_DATETIME}.log| ssh -p${REMOTE_PORT} ${REMOTE_USER}@${REMOTE_HOST} "cat - > ${REMOTE_BACKUP_DIR}/${BACKUP_PREFIX_NAME}_${BACKUP_DATETIME}.xb"
    local BAKUP_END_TIME=`date +"%Y-%m-%d %H:%M:%S"`
    
    check_backup_status

    if [[ ${DINGDING_SWITCH} -eq 1 ]];then
      local LOCAL_DISK_USE=${LOCAL_DISK_CMD}
      local REMOTE_DISK_USE=`ssh -p${REMOTE_PORT} ${REMOTE_USER}@${REMOTE_HOST} ${REMOTE_DISK_USE_CMD}`
      local BACKUP_FILE_SIZE_CMD="ls -lh ${REMOTE_BACKUP_DIR}/${BACKUP_PREFIX_NAME}_${BACKUP_DATETIME}.xb|awk '{print \$5}'"
      local BACKUP_FILE_SIZE=`ssh -p${REMOTE_PORT} ${REMOTE_USER}@${REMOTE_HOST} "${BACKUP_FILE_SIZE_CMD}"`
      local DING_MSG="**通知内容:**\n* 执行备份服务器:${IPADDR}\n* 本地备份目录：${BACKUP_DIR}\n* 磁盘使用率：${LOCAL_DISK_USE}\n* 远程备份主机：${REMOTE_HOST}\n* 远程备份文件:${BACKUP_PREFIX_NAME}_${BACKUP_DATETIME}.xb\n* 远程备份大小：${BACKUP_FILE_SIZE}\n* 远程备份目录：${REMOTE_BACKUP_DIR}\n* 远程磁盘使用率：${REMOTE_DISK_USE}\n* 备份开始时间:${BAKUP_BEGIN_TIME}\n* 备份结束时间:${BAKUP_END_TIME}\n---\n**通知时间:** \n \n`date '+%Y-%m-%d %H:%M:%S'`"
      if [ ${BACKUP_STATUS} -eq 1 ];then
        dingding_note "通知" "${DING_MSG}"
      else
        dingding_note "异常" "${DING_MSG}"
      fi
    fi
    print_message "Note" "远程备份完成"
}

# 清除历史备份
his_backup_clean()
{	
    print_message "Note" "开始清理历史备份"
    if [[ ${REMOTE_BACKUP_SWITCH} -eq 1 ]];then
      REMOTEBACK_FILES=`ssh -p${REMOTE_PORT} ${REMOTE_USER}@${REMOTE_HOST} "ls ${REMOTE_BACKUP_DIR}|wc -l"`
      if [ ${REMOTEBACK_FILES} -gt 0 ];then
        REMOTEBACK_BACKUP_FILES=`ssh -p${REMOTE_PORT} ${REMOTE_USER}@${REMOTE_HOST} "ls ${REMOTE_BACKUP_DIR}/${BACKUP_PREFIX_NAME}_*.xb|wc -l"`
        if [ ${REMOTEBACK_BACKUP_FILES} -gt 0 ];then
        ssh -p${REMOTE_PORT} ${REMOTE_USER}@${REMOTE_HOST} "find ${REMOTE_BACKUP_DIR} -type f -name ${BACKUP_PREFIX_NAME}_*.xb -mtime +${BACKUP_SAVE_DAYS} -exec rm -rf {} \;"
        find ${BACKUP_LOG} -type f -name "${BACKUP_PREFIX_NAME}_*.log" -mtime +${BACKUP_SAVE_DAYS} -exec rm -rf {} \;
        fi
      else
        print_message "Warning" "当前远程备份文件为空,无需清理."
      fi
    else
      if [ -d ${BACKUP_DIR} ];then
        find ${BACKUP_DIR} -type f -name "${BACKUP_PREFIX_NAME}_*.xb" -mtime +${BACKUP_SAVE_DAYS} -exec rm -rf {} \;
        find ${BACKUP_LOG} -type f -name "${BACKUP_PREFIX_NAME}_*.log" -mtime +${BACKUP_SAVE_DAYS} -exec rm -rf {} \;
      fi
    fi
    print_message "Note" "清理历史备份清理完成"
}

# 钉钉信息发送
## $1 通知/异常
## $2 发送信息
dingding_note(){
  if [[ ${DINGDING_SWITCH} -eq 1 ]];then
    if [ ! -f /usr/bin/dingtalk_send ];then
      if [ -f $PARENT_DIR/lib/dingtalk_send ];then
        print_info "将 dingtalk_send 拷贝到 /usr/bin"
        cp $PARENT_DIR/lib/dingtalk_send /usr/bin
      else
        print_error "请先将 dingtalk_send 拷贝到 /usr/bin"
      fi      
    fi

    print_message "通知" "发送钉钉通知..."
    if [[ $1 == "通知" ]]; then
      local color="#006600"
    else
      local color="#FF0033"
    fi
    local DING_MESSAGE="**[<font color=${color}>$1</font>]** \n \n--- \n$2"
    if [[ ${IS_AT_ALL} ]];then
      DING_STATUS=`/usr/bin/dingtalk_send -url "${WEBHOOK_URL}" -secert "${SECRET}" -title "${MSG_TITLE}" -type "${SEND_TYPE}" -msg "${DING_MESSAGE}" -at_all`
    elif [[ ${AT_MOBILES} ]];then
     DING_STATUS=`/usr/bin/dingtalk_send -url "${WEBHOOK_URL}" -secert "${SECRET}" -title "${MSG_TITLE}" -type "${SEND_TYPE}" -msg "${DING_MESSAGE}" -at_mobiles ${AT_MOBILES}`
    else
      #echo "${CURRENT_DIR}/dingtalk_send -url \"${WEBHOOK_URL}\" -secert \"${SECRET}\" -title \"${MSG_TITLE}\" -type \"${SEND_TYPE}\" -msg \"${DING_MESSAGE}\""
      DING_STATUS=`/usr/bin/dingtalk_send -url "${WEBHOOK_URL}" -secert "${SECRET}" -title "${MSG_TITLE}" -type "${SEND_TYPE}" -msg "${DING_MESSAGE}"`
    fi
    if [ "${DING_STATUS}" = '{"errcode":0,"errmsg":"ok"}' ];then
      print_message "Note" "钉钉消息发送成功"
    else
      print_message "Error" "钉钉消息发送失败,请检查! 钉钉命令为 dingding_note \"通知\" \"${DING_MSG}\""
      exit 1
    fi
    print_message "通知" "钉钉通知完成..."
  fi
}

do_backup(){
    # 检查后台是否有xtrabackup进程
    local XTRA_PROCESS=`ps -ef | grep -v "grep" | grep ${XTRABACKUP_PATH} | wc -l`
    if [[ ${XTRA_PROCESS} -eq 0 ]];then
      backup_environment_check
      his_backup_clean
      if [[ ${REMOTE_BACKUP_SWITCH} -eq 1 ]];then
        xbstream_compress_backup_remote
      else
        xbstream_compress_backup_local
      fi
    else
      print_message "Error" "已有备份正在运行"
      dingding_note "异常" "已有备份正在运行，请检查！！！"
      exit 1 
    fi
}

# 检查备份是否成功
check_backup_status(){
  BACKUP_STATUS=`tail -5 ${BACKUP_LOG}/${BACKUP_PREFIX_NAME}_${BACKUP_DATETIME}.log |grep "completed OK"|wc -l`
  if [ ${BACKUP_STATUS} -eq 1 ];then
    print_message "Note" "备份[${BACKUP_PREFIX_NAME}_${BACKUP_DATETIME}.xb]成功"
  else
    print_message "Error" "备份[${BACKUP_PREFIX_NAME}_${BACKUP_DATETIME}.xb]失败"
    print_message "Error" "日志文件为 ${BACKUP_LOG}/${BACKUP_PREFIX_NAME}_${BACKUP_DATETIME}.log"
    XTRA_ERROR_MSG=`tail -50 ${BACKUP_LOG}/${BACKUP_PREFIX_NAME}_${BACKUP_DATETIME}.log`
    print_message "Error" "错误信息为: ${XTRA_ERROR_MSG}"
    local DING_MSG="**<font color=#FF0033>备份失败,请检查!!!</font>**\n* 执行备份服务器:${IPADDR}\n* 备份文件:${BACKUP_PREFIX_NAME}_${BACKUP_DATETIME}.xb\n* 备份目录：${BACKUP_DIR}\n* 日志文件:${BACKUP_PREFIX_NAME}_${BACKUP_DATETIME}.log\n* 日志目录:${BACKUP_LOG}\n---\n**通知时间:** \n \n`date '+%Y-%m-%d %H:%M:%S'`"
    dingding_note "异常" "${DING_MSG}"
    exit 1
  fi 
}

# 添加定时任务
add_job_crontab()
{ 
  dingding_note "备份设置" "设置定时备份为每天凌晨2点55分执行\n\n 通知时间: `date +%F-%T`"

  cat >> /etc/crontab << EOF
# 每天凌晨2点55分执行备份
55 02 * * * root /bin/bash $1 > ${BACKUP_LOG}/${BACKUP_PREFIX_NAME}_\`date '+\%Y\%m\%d\%H\%M\%S'\`_script.log 2>&1
EOF
}

if [ "$1" = "addcron" ]; then
    add_job_crontab "${CURRENT_DIR}/$(basename "$0") backup" && echo -e "\033[32m *****add crontab success***** \033[0m"
    cat /etc/crontab
elif [ "$1" = "backup" ]; then
  do_backup
else
  printf "Usage:
      $0 backup  执行备份
      $0 addcron 添加定时任务,默认为每天凌晨2点55分执行备份,有需求自行修改\n"
fi
