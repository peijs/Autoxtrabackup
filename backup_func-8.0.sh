#!/bin/bash
# 此脚本只适用于mysql8版本,早先的5.6,5.7版本不能混用(会由tools变量做安装包检测)
# crontab设置:(每天0点全备,其他时间每隔两小时一次增量)
# 0 0 * * * /home/backups/backup_func.sh full
# 0 2-22/2 * * * /home/backups/backup_func.sh incr
# 备份用户创建及权限配置(密码随机生成`openssl rand -base64 12 | cut -b 1-12`)
# mysql> CREATE USER 'bkpuser'@'localhost' IDENTIFIED BY 'xxxxxxxxxx';
# mysql> GRANT BACKUP_ADMIN, PROCESS, RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'bkpuser'@'localhost';
# mysql> GRANT SELECT ON performance_schema.log_status TO 'bkpuser'@'localhost';
# mysql> GRANT SELECT ON performance_schema.keyring_component_status TO bkpuser@'localhost'
# mysql> FLUSH PRIVILEGES;
. /etc/profile
# 备份相关基础路径(必填!!!)
BACKUPDIR=/DataBackup/ZabbixMysql-8.0.27-Backup
# 全量备份目录
Full=$BACKUPDIR/full
# 增量备份目录
Incr=$BACKUPDIR/incr
# 备份归档路径
Old=$BACKUPDIR/old
# 日志路径
baklog=$BACKUPDIR/backup.log
# 日期信息,用于区分当天备份用于归档
# TODAY=$(date +%Y%m%d%H%M)
YESTERDAY=$(date -d"yesterday" +%Y%m%d)

# Mysql实例相关信息(必填!!!)
MYSQL=/data/GYXY/mysql-8.0.27/bin/mysql
MYSQLADMIN=/data/GYXY/mysql-8.0.27/bin/mysqladmin
DB_HOST='127.0.0.1' # 填写localhost时,会尝试使用socket连接
DB_PORT=3306        # 这里没有用到,需要的话,在备份命令也加上端口参数
DB_USER='root'
DB_PASS='toortoor'
DB_SOCK=/data/GYXY/mysql-8.0.27/mysql.sock
DB_CONF=/data/GYXY/mysql-8.0.27/my.cnf

# 备份必备工具检查(压缩备份需要qpresss)
#tools="percona-xtrabackup-80 qpress"
# Check packages before proceeding
#for i in $tools; do
#    if ! [[ $(rpm -qa $i) =~ ${i} ]]; then
#        echo -e " Needed package $i not found.\n Pre check failed !!!"
#        exit 1
#    fi
#done

# mysql 运行状态监测
if [ -z "$($MYSQLADMIN --host=$DB_HOST --socket=${DB_SOCK} --user=$DB_USER --password=$DB_PASS --port=$DB_PORT status | grep 'Uptime')" ]; then
    echo -e "HALTED: MySQL does not appear to be running or incorrect username and password"
    exit 1
fi

# 备份用户名密码监测 # 好像有点多余...
if ! $(echo 'exit' | $MYSQL -s --host=$DB_HOST --socket=${DB_SOCK} --user=$DB_USER --password=$DB_PASS --port=$DB_PORT); then
    echo -e "HALTED: Supplied mysql username or password appears to be incorrect (not copied here for security, see script)."
    exit 1
fi

####################################################
#归档备份函数(全量时自动触发)
####################################################
function Xtr_tar_backup() {
    # if [ ! -d "${Old}" ]; then
    #     mkdir ${Old}
    # fi
    for i in $Full $Incr $Old; do
        if [ ! -d $i ]; then
            mkdir -pv $i
        fi
    done
    # 压缩上传前一天的备份
    echo "压缩前一天的备份，移动到${Old}"
    cd $BACKUPDIR
    tar -zcvf $YESTERDAY.tar.gz ./full/ ./incr/
    #scp -P 8022 $YESTERDAY.tar.gz root@192.168.10.46:/data/backup/mysql/
    mv $YESTERDAY.tar.gz $Old
    if [ $? = 0 ]; then
        rm -rf $Full $Incr
        echo "Tar old backup succeed" | tee -a ${baklog} 2>&1
    else
        echo "Error with old backup." | tee -a ${baklog} 2>&1
    fi
}

####################################################
#全量备份函数(手动触发)
####################################################
function Xtr_full_backup() {
    if [ ! -d "${Full}" ]; then
        mkdir ${Full}
    fi
    Xtr_tar_backup
    # 第一步 创建本次的备份目录
    FullBakTime=$(date +%Y%m%d-%H%M%S)
    mkdir -p ${Full}/${FullBakTime}
    FullBakDir=${Full}/${FullBakTime}
    # 第二步 开始全量备份
    echo -e "备份时间: ${FullBakTime}\n" | tee -a ${baklog} 2>&1
    echo -e "本次全量备份目录为 ${FullBakDir}\n" | tee -a ${baklog} 2>&1
    xtrabackup --defaults-file=${DB_CONF} --host=${DB_HOST} --port=$DB_PORT --user=${DB_USER} --password=${DB_PASS} --socket=${DB_SOCK} --backup --compress --compress-threads=4 --target-dir=${FullBakDir}
    dirStorage=$(du -sh ${FullBakDir})
    echo -e "本次备份数据 ${dirStorage}\n" | tee -a ${baklog} 2>&1
    echo -e "备份完成...\n\n\n" | tee -a ${baklog} 2>&1
    exit 0
}

####################################################
#增量备份函数(手动触发)
####################################################
function Xtr_incr_backup() {
    # 第一步 获取上一次全量备份和增量备份信息
    LATEST_INCR=$(find $Incr -mindepth 1 -maxdepth 1 -type d | sort -nr | head -1)
    LATEST_FULL=$(find $Full -mindepth 1 -maxdepth 1 -type d | sort -nr | head -1)
    if [ ! $LATEST_FULL]; then
        echo "xtrabackup_info does not exist. Please make sure full backup exist."
        exit 1
    fi
    echo "LATEST_INCR=$LATEST_INCR"
    if [ ! -d "${Incr}" ]; then
        mkdir ${Incr}
    fi
    # 判断上一次的备份路径,如果增量备份路径为空,则使用全量备份路径为--incremental-basedir
    if [ ! $LATEST_INCR ]; then
        CompliteLatestFullDir=$LATEST_FULL
    else
        CompliteLatestFullDir=$LATEST_INCR
    fi
    # 第二步 创建备份目录
    IncrBakTime=$(date +%Y%m%d-%H%M%S)
    mkdir -p ${Incr}/${IncrBakTime}
    IncrBakDir=${Incr}/${IncrBakTime}
    # 第三步 开始增量备份
    echo -e "日期: ${IncrBakTime}\n" | tee -a ${baklog} 2>&1
    echo -e "整点: ${Hour}\n" | tee -a ${baklog} 2>&1
    echo -e "本次备份为基于上一次备份${CompliteLatestFullDir}的增量备份\n" | tee -a ${baklog} 2>&1
    echo -e "本次增量备份目录为: ${IncrBakDir}\n" | tee -a ${baklog} 2>&1
    xtrabackup --defaults-file=${DB_CONF} --host=${DB_HOST} --port=$DB_PORT --user=${DB_USER} --password=${DB_PASS} --socket=${DB_SOCK} --backup --compress --compress-threads=4 --parallel=4 --target-dir=${IncrBakDir} --incremental-basedir=${CompliteLatestFullDir}
    dirStorage=$(du -sh ${IncrBakDir})
    echo -e "本次备份数据 ${dirStorage}\n" | tee -a ${baklog} 2>&1
    echo -e "备份完成...\n\n\n" | tee -a ${baklog} 2>&1
    exit 0
}

####################################################
#主体备份函数
####################################################
function printInfo() {
    echo "Your choice is $1"
}
case $1 in
"full")
    echo "Your choice is $1"
    Xtr_full_backup
    ;;
"incr")
    echo "Your choice is $1"
    Xtr_incr_backup
    ;;
*)
    echo -e "No parameters specified!\nFor example:\n$0 full\n$0 incr"
    ;;
esac
exit 0
