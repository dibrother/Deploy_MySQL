#!/bin/bash

# note: 下载涉及的依赖包
MYSQL8_DOWNLOAD_VERSION=8.0.37
MYSQL5_DOWNLOAD_VERSION=5.7.44
REPLICATION_MANAGER_VERSION=2.3.40


MYSQL_DEPLOY_VERSION=v0.1.1
base_rul="https://github.com/dibrother/Deploy_MySQL/releases/download/${MYSQL_DEPLOY_VERSION}"

CURRENT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )
PARENT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." >/dev/null 2>&1 && pwd )
source $PARENT_DIR/conf/mysql.cnf
source $CURRENT_DIR/print_log.sh

# 检查架构
arm_or_x86=$(uname -m)

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

# 在线下载mysql
function online_download_mysql(){
  if [[ $MYSQL_VERSION == "8.0" ]];then
    print_info "正在下载 MySQL 二进制包,版本：${MYSQL8_DOWNLOAD_VERSION}"
    local mysql_dowmload_url="https://downloads.mysql.com/archives/get/p/23/file/mysql-${MYSQL8_DOWNLOAD_VERSION}-linux-glibc2.17-${arm_or_x86}.tar.xz"
    local mysql_dowmload_file_name=$PARENT_DIR/lib/$(basename "$mysql_dowmload_url")
  elif [[ $MYSQL_VERSION == "5.7" ]];then
    print_info "正在下载 MySQL 二进制包,版本：${MYSQL5_DOWNLOAD_VERSION}"
    local mysql_dowmload_url="https://downloads.mysql.com/archives/get/p/23/file/mysql-${MYSQL5_DOWNLOAD_VERSION}-linux-glibc2.12-x86_64.tar.gz"
    local mysql_dowmload_file_name=$PARENT_DIR/lib/$(basename "$mysql_dowmload_url")
  fi

  download_file $mysql_dowmload_url $mysql_dowmload_file_name
}

# 在线下载 replication-manager
function online_download_replication_manager(){
    print_info "正在下载 replication-manager 相关组件，版本：${REPLICATION_MANAGER_VERSION}..."
    if [[ ${OS_PACKAGE} == "rpm" ]]; then
      if [ "$arm_or_x86" = "x86_64" ]; then
        local ha_client_dowmload_url="https://ci.signal18.io/mrm/builds/tags/v${REPLICATION_MANAGER_VERSION}/replication-manager-client-${REPLICATION_MANAGER_VERSION}-1.x86_64.rpm"
        local ha_client_file_name=$PARENT_DIR/lib/$(basename "$ha_client_dowmload_url")
        local ha_osc_dowmload_url="https://ci.signal18.io/mrm/builds/tags/v${REPLICATION_MANAGER_VERSION}/replication-manager-osc-${REPLICATION_MANAGER_VERSION}-1.x86_64.rpm"
        local ha_osc_file_name=$PARENT_DIR/lib/$(basename "$ha_osc_dowmload_url")
      elif [ "$arm_or_x86" = "aarch64" ]; then
        local ha_client_dowmload_url="https://ci.signal18.io/mrm/builds/tags/v${REPLICATION_MANAGER_VERSION}/replication-manager-client-${REPLICATION_MANAGER_VERSION}-1.aarch64.rpm"
        local ha_client_file_name=$PARENT_DIR/lib/$(basename "$ha_client_dowmload_url")
        local ha_osc_dowmload_url="https://ci.signal18.io/mrm/builds/tags/v${REPLICATION_MANAGER_VERSION}/replication-manager-osc-${REPLICATION_MANAGER_VERSION}-1.aarch64.rpm"
        local ha_osc_file_name=$PARENT_DIR/lib/$(basename "$ha_osc_dowmload_url")
      else
        print_error "不支持的架构,当前支持 x86_64 或 arm64."
        exit 1
      fi
    elif [[ ${OS_PACKAGE} == "deb" ]]; then
      if [ "$arm_or_x86" = "x86_64" ]; then
        local ha_client_dowmload_url="https://ci.signal18.io/mrm/builds/tags/v${REPLICATION_MANAGER_VERSION}/replication-manager-client-${REPLICATION_MANAGER_VERSION}_amd64.deb"
        local ha_client_file_name=$PARENT_DIR/lib/$(basename "$ha_client_dowmload_url")
        local ha_osc_dowmload_url="https://ci.signal18.io/mrm/builds/tags/v${REPLICATION_MANAGER_VERSION}/replication-manager-osc-${REPLICATION_MANAGER_VERSION}_amd64.deb"
        local ha_osc_file_name=$PARENT_DIR/lib/$(basename "$ha_osc_dowmload_url")
      elif [ "$arm_or_x86" = "aarch64" ]; then
        local ha_client_dowmload_url="https://ci.signal18.io/mrm/builds/tags/v${REPLICATION_MANAGER_VERSION}/replication-manager-client_${REPLICATION_MANAGER_VERSION}_arm64.deb"
        local ha_client_file_name=$PARENT_DIR/lib/$(basename "$ha_client_dowmload_url")
        local ha_osc_dowmload_url="https://ci.signal18.io/mrm/builds/tags/v${REPLICATION_MANAGER_VERSION}/replication-manager-osc-${REPLICATION_MANAGER_VERSION}_arm64.deb"
        local ha_osc_file_name=$PARENT_DIR/lib/$(basename "$ha_osc_dowmload_url")
      else
        print_error "不支持的架构,当前支持 x86_64 或 arm64."
        exit 1
      fi
    else
      print_error "不支持的架构,当前支持 redhat系列 或 Debain系列."
      exit 1
    fi

    download_file $ha_client_dowmload_url $ha_client_file_name
    download_file $ha_osc_dowmload_url $ha_osc_file_name
}


# if [[ ${OS_PACKAGE} == "rpm" ]]; then
#     pkg_url="${baseurl}/Deploy_MySQL-pkg-${MYSQL_DEPLOY_VERSION}.el${OS_VERSION}.x86_64.tgz"
# elif [[ ${OS_PACKAGE} == "deb" ]]; then
#     pkg_url="${baseurl}/Deploy_MySQL-pkg-${MYSQL_DEPLOY_VERSION}.debian12.x86_64.tgz"
# fi

# 获取系统与版本
function check_vendor_version(){
  if [[ -f /etc/os-release ]]; then
      . /etc/os-release
      OS_VENDOR="$ID"
      OS_VERSION="$VERSION_ID"
      OS_CODENAME=${VERSION_CODENAME-''}
      if [[ $VERSION_ID == *.* ]]; then
          OS_VERSION=$(echo "$VERSION_ID" | cut -d. -f1)
      else
          OS_VERSION="${VERSION_ID}"
      fi
      print_info "vendor = ${OS_VENDOR} (${NAME})"
      print_info "version = ${OS_VERSION} (${VERSION_ID})"
      return 0
  else
      print_info "/etc/os-release file not found, unknown OS"
      exit 5
  fi
}

function download_file() {
    local file_url=$1
    local output_file=$2

    if [[ -f "$output_file" ]]; then
        print_info "文件 $output_file 已存在，跳过下载"
        return
    fi

    #wget -c "$file_url" -O "$output_file"
    curl -L "$file_url" -o "$output_file"
}

# 检查能否上外网
function check_net(){
  ping -c 1 8.8.8.8 > /dev/null 2>&1
  if [ $? -eq 0 ]; then
    return 0
  else
    return 1
  fi
}

check_package_manager
if check_net;then
  online_download_mysql
  online_download_replication_manager
else
  print_warning "无法连通外网，请使用离线部署，请至 https://github.com/dibrother/Deploy_MySQL/releases/${base_rul} 下载对应的包解压至 lib 目录内"
  exit 1
fi