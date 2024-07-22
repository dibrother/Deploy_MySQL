#!/bin/bash
#desc: 生成密钥对，批量拷贝公钥到远端机器

#定义变量  用户:ip:密码:端口
servers=(root:10.10.2.10:yQ@010203:22 root:10.10.2.11:yQ@010203:22 root:10.10.2.13:yQ@010203:22)

# 检查是否已设置hosts
function check_config_hosts(){
   for server_info in "${servers[@]}";do
     IFS=':' read -r username hostip passwd port <<< "$server_info"
     local chk_result=$(grep -q "$hostip" /etc/hosts)
     if [[ $chk_result -gt 0 ]];then
        echo "请先配置 /etc/hosts !"
        exit 1
     fi
   done
}

function install_sshpass(){
if command -v yum &> /dev/null; then
        package_manager="yum"
    elif command -v apt-get &> /dev/null; then
        package_manager="apt-get"
    else
        package_manager="none"
fi

# 检查sshpass是否安装
if ! command -v sshpass &> /dev/null; then
    echo "sshpass 未安装,安装 sshpass..."
    $package_manager install -y sshpass
fi
}

#生成密钥对
function generate_key(){
if [ ! -f ~/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa
fi
}

#拷贝公钥到远端
function do_sshpass(){
for server_info in "${servers[@]}";do
    IFS=':' read -r username hostip passwd port <<< "$server_info"
    sshpass -p ${passwd} ssh-copy-id -o StrictHostKeyChecking=no -p $port ${username}@${hostip} &> /dev/null 
    if [ $? -eq 0 ];then
        echo "拷贝到 ${hostip} 成功"
    else
        echo -e "\033[0;31m拷贝到 ${hostip} 失败 \033[0m"
    fi
  done
}

#验证免密是否成功
function check_pass(){
  for server_info in "${servers[@]}";do
    IFS=':' read -r username hostip passwd port <<< "$server_info"
    hostname_result=$(ssh -n ${hostip} hostname)
    echo "连接 $hostip 免密成功"
    ssh -n -o StrictHostKeyChecking=no -p $port $hostname_result &> /dev/null 
    if [ $? -gt 0 ];then 
      echo -e "\033[0;31m连接 $hostip 的 hostname [$hostname_result] 免密失败 \033[0m"
    else
      echo "连接 $hostip 的 hostname [$hostname_result] 免密成功"
    fi
  done
}

check_config_hosts
install_sshpass
generate_key
do_sshpass
check_pass

