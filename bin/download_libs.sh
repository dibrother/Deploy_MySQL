#!/bin/bash

# note: 下载涉及的依赖包

CURRENT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )
source $CURRENT_DIR/mysql.sh

# 检查架构
arm_or_x86=$(uname -m)


function download_file() {
    local file_url=$1
    local output_file=$2

    if [[ -f "$output_file" ]]; then
        print_info "文件 $output_file 已存在，跳过下载"
        return
    fi

    wget -c "$file_url" -O "$output_file"
}

function download_mysql(){
  if [[ $MYSQL_VERSION == "8.0" ]];then
    print_info "正在下载 MySQL8..."
    if [ "$arm_or_x86" = "x86_64" ]; then
      download_file "https://dev.mysql.com/get/Downloads/MySQL-8.0/mysql-8.0.37-linux-glibc2.17-x86_64.tar.xz" "$PARENT_DIR/lib/mysql-8.0.37-linux-glibc2.17-x86_64.tar.xz"
    elif [ "$arm_or_x86" = "aarch64" ]; then
      download_file https://dev.mysql.com/get/Downloads/MySQL-8.0/mysql-8.0.37-linux-glibc2.17-aarch64.tar.xz "$PARENT_DIR/lib/mysql-8.0.37-linux-glibc2.17-aarch64.tar.xz"
    else
      print_error "不支持的架构,当前支持 x86_64 或 arm64."
    fi
  elif [[ $MYSQL_VERSION == "5.7" ]];then
    print_info "正在下载 MySQL5.7..."
    if [ "$arm_or_x86" = "x86_64" ]; then
      download_file "https://downloads.mysql.com/archives/get/p/23/file/mysql-5.7.44-linux-glibc2.12-i686.tar.gz" "$PARENT_DIR/lib/mysql-5.7.44-linux-glibc2.12-i686.tar.gz"
    else
      print_error "5.7 不支持部署 arm 架构."
    fi
  fi

}

function download_replication_manager(){
    print_info "正在下载 replication-manager-client-2.3.40..."
    if [ "$arm_or_x86" = "x86_64" ]; then
      download_file https://ci.signal18.io/mrm/builds/tags/v2.3.40/replication-manager-client-2.3.40-1.x86_64.rpm "$PARENT_DIR/lib/replication-manager-client-2.3.40-1.x86_64.rpm"
      download_file https://ci.signal18.io/mrm/builds/tags/v2.3.40/replication-manager-osc-2.3.40-1.x86_64.rpm "$PARENT_DIR/lib/replication-manager-osc-2.3.40-1.x86_64.rpm"
    elif [ "$arm_or_x86" = "aarch64" ]; then
      download_file https://ci.signal18.io/mrm/builds/tags/v2.3.40/replication-manager-client-2.3.40-1.aarch64.rpm "$PARENT_DIR/lib/replication-manager-client-2.3.40-1.aarch64.rpm"
      download_file https://ci.signal18.io/mrm/builds/tags/v2.3.40/replication-manager-osc-2.3.40-1.aarch64.rpm "$PARENT_DIR/lib/replication-manager-osc-2.3.40-1.aarch64.rpm"
    else
      print_error "不支持的架构,当前支持 x86_64 或 arm64."
    fi
}

function download_xtrabackup(){
  if [[ $MYSQL_VERSION == "8.0" ]];then
    print_info "正在下载 percona-xtrabackup-80-8.0.35-31..."
    if [ "$arm_or_x86" = "x86_64" ]; then
      download_file https://downloads.percona.com/downloads/Percona-XtraBackup-8.0/Percona-XtraBackup-8.0.35-31/binary/redhat/8/x86_64/percona-xtrabackup-80-8.0.35-31.1.el8.x86_64.rpm?_gl=1*kqf0jp*_gcl_au*NjM4MDc2MDk3LjE3MTg2ODkxNjc. "$PARENT_DIR/lib/percona-xtrabackup-80-8.0.35-31.1.el8.x86_64.rpm"
    else
      download_file https://downloads.percona.com/downloads/Percona-XtraBackup-8.0/Percona-XtraBackup-8.0.35-31/binary/redhat/8/aarch64/percona-xtrabackup-80-8.0.35-31.1.el8.aarch64.rpm?_gl=1*6aj477*_gcl_au*NjM4MDc2MDk3LjE3MTg2ODkxNjc. "$PARENT_DIR/lib/percona-xtrabackup-80-8.0.35-31.1.el8.aarch64.rpm"
    fi
  elif [[ $MYSQL_VERSION == "5.7" ]];then
    if [ "$arm_or_x86" = "x86_64" ]; then
      download_file https://downloads.percona.com/downloads/Percona-XtraBackup-2.4/Percona-XtraBackup-2.4.29/binary/redhat/8/x86_64/percona-xtrabackup-24-2.4.29-1.el8.x86_64.rpm?_gl=1*17fb224*_gcl_au*NjM4MDc2MDk3LjE3MTg2ODkxNjc. "$PARENT_DIR/lib/percona-xtrabackup-24-2.4.29-1.el8.x86_64.rpm"
    else
      print_error "不支持部署 5.7 arm 架构的xtrabackup！"
    fi
  fi
}

download_mysql
download_xtrabackup
download_replication_manager