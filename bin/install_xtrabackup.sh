#!/bin/bash
set -e

CURRENT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )
PARENT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." >/dev/null 2>&1 && pwd )
source $PARENT_DIR/conf/mysql.cnf
source $CURRENT_DIR/print_log.sh

# 检查能否上外网
function check_net(){
  ping -c 1 8.8.8.8 > /dev/null 2>&1
  if [ $? -eq 0 ]; then
    return 0
  else
    return 1
  fi
}

function check_package_manager(){
    # get package / manager: rpm|deb and dnf|yum|apt|apt-get|zypper
    if command -v dpkg >/dev/null 2>&1; then
        OS_PACKAGE="deb"
        if command -v apt >/dev/null 2>&1; then
            OS_MANAGER="apt"
        elif command -v apt-get >/dev/null 2>&1; then
            OS_MANAGER="apt-get"
        else
            print_error "fail to determine os package manager for deb"
            exit 4
        fi
    elif command -v rpm >/dev/null 2>&1; then
        OS_PACKAGE="rpm"
        if command -v dnf >/dev/null 2>&1; then
            OS_MANAGER="dnf"
        elif command -v yum >/dev/null 2>&1; then
            OS_MANAGER="yum"
        elif command -v zypper >/dev/null 2>&1; then
            OS_MANAGER="zypper"
        else
            print_error "fail to determine os package manager for rpm"
            exit 4
        fi
    else
        print_error "fail to determine os package type"
        exit 3
    fi
    print_info "当前系统包管理使用的是: ${OS_PACKAGE},${OS_MANAGER}"
}

function online_install_xtrabackup8(){
    if [[ ${OS_PACKAGE} == "rpm" ]]; then
        yum install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm
        percona-release enable-only tools release
        yum install -y percona-xtrabackup-80
    elif [[ ${OS_PACKAGE} == "deb" ]]; then
        wget https://repo.percona.com/apt/percona-release_latest.$(lsb_release -sc)_all.deb
        dpkg -i percona-release_latest.$(lsb_release -sc)_all.deb
        percona-release enable-only tools release
        apt update
        apt install percona-xtrabackup-80
    else
        print_error "不支持的架构,当前支持 x86_64 或 arm64."
        exit 1
    fi
}

function online_install_xtrabackup5(){
    if [[ ${OS_PACKAGE} == "rpm" ]]; then
        yum install https://repo.percona.com/yum/percona-release-latest.noarch.rpm
        percona-release enable-only tools release
        yum install percona-xtrabackup-24
        yum install qpress
    elif [[ ${OS_PACKAGE} == "deb" ]]; then
        wget https://repo.percona.com/apt/percona-release_latest.$(lsb_release -sc)_all.deb
        dpkg -i percona-release_latest.$(lsb_release -sc)_all.deb
        percona-release enable-only tools release
        apt install percona-xtrabackup-24
        apt install qpress
    else
        print_error "不支持的架构,当前支持 x86_64 或 arm64."
        exit 1
    fi

}

function install_xtrabackup_online(){
    if [ ! -x ${XTRABACKUP_PATH} ];then
        check_package_manager 
        
	fi
}
