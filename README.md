# 简介

实现MySQL的集群一键部署，支持单机、主从、高可用的部署，同时使用 xreabackup 进行备份恢复，在有网络的情况下可进行钉钉通知

# 功能

* 部署单机 MySQL
* 部署主从MySQL
* 部署高可用版本MySQL

* 使用 xtrabackup进行全量备份
* 使用 xtrabackup进行快速恢复，重建主从、
* 支持 arm64/x86_64 架构
* 支持 Redhat/Debain 系列

## 架构

![image-20240723142654559](https://cdn.jsdelivr.net/gh/dibrother/blogImages/img/202407231427844.png)

* MySQL 使用主从增强半同步方式
* 使用 Replication-manager 作为高可用组件
* 使用 Percona Xtrabackup 作为备份恢复软件

## 限制

* 当前不支持启用 event，启用后进行switchover切换后,可能出现数据错乱（从库执行了event）
* 当前支持 5.7/8.0版本,8.1~9.0未经过完全测试
* 当前基于MySQL 85.7.44/MySQL 8.0.37 版本测试，默认下载版本为 8.0.37

# 使用

## 下载依赖包

需要下载对应的依赖包，默认下载 8.0.37版本

```shell
cd ../Deploy_MySQL/bin
./download_libs.sh 
```

> 如果需要下载

## 部署单机

```shell
```

