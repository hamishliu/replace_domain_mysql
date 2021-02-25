#!/bin/bash

#变量配置
cd `dirname $0`
work_dir=$(pwd)
coding_tool_dir="/data/coding-tools"

#DB_HOST="9.134.113.188"   #手动指定IP
[ $(kubectl -ncoding get svc |grep -w 'mysql '|wc -l) -eq 1 ] && DB_HOST=$(kubectl -ncoding get svc |grep -w 'mysql '|awk '{print $3}') || DB_HOST=$(kubectl -ncoding get cm infra-mysql-cm -o jsonpath={.data.host})    #自动获取当前DB地址

#DB_PORT=3306      ##手动指定端口
[ $(kubectl -ncoding get svc |grep mysql|grep 3306|wc -l) -eq 1 ] && DB_PORT=3306 || DB_PORT=$(kubectl -ncoding get cm infra-mysql-cm -o jsonpath={.data.port})  #自动获取D 端口

#DB_USER="root"
DB_USER=$(kubectl -ncoding get cm infra-mysql-cm -o jsonpath={.data.username})

#DB_PASSWD="488581ee7a751d2ba51a3ac9dad6e1b8"  #手动指定密码
DB_PASSWD=$(kubectl -ncoding get cm infra-mysql-cm -o jsonpath={.data.password})    #自动获取当前环境密码

#old_domain="coding.io"  #手动指定旧域名
old_domain=$(cat $coding_tool_dir/apps/coding-helm/values.yaml |grep private_domain |awk -F ' ' '{print $2}')  #自动获取当前环境域名
new_domain=$old_domain
record_date=$(date +\%Y-\%m-\%d_\%H\%M\%S)

token="Y29kaW5nMTIzIQ=="






function help() {
    echo "Usage:	$0 [OPTIONS] COMMAND"
    echo ""
    echo "              -c 前置配置及环境检查"
    echo "              -f 可选，需要执行的步骤，可选值有"
    echo "                 all: 一键替换域名,自动更新DB数据及helm配置,并重新滚动重启coding业务pod"
    echo "                 search: 全库全表检索包含当前域名的DB数据,并生成替换域名的sql脚本"
    echo "                 updatedb: 根据生成的域名替换SQL脚本正式执行更新"
    echo "                 updatecoredns: 更新CoreDNS域名解析"
    echo "                 reinstall: 重新部署coding业务模块,部署过程会自动重启存量coding业务pod"
    echo ""
    echo "              -o 可选，指定需要替换的旧域名，默认取当前脚本内的变量old_domain"
    echo "              -n 可选，指定需要替换的新域名，默认取当前脚本内的变量new_domain"
    echo "              -h 显示帮助信息"

    echo "
example:

   $0 -f search -o "test.coding.cn" -n "coding.io"  #一键检索全库历史域名数据，并生成db更新脚本
   $0 -f all -o "test.coding.cn" -n "coding.io"     #一键替换，域名取传的变量参数
   $0 -f all                                    #一键替换，域名配置文件取脚本内定义值

Log path: $coding_tool_dir/replace_domain/ 

"
}


if [ -z "$1" ];then
    help
    exit 1
fi


while getopts 'h:c:f:o:n:' OPT
do
    case $OPT in
        c)
        check="true"
        ;;
        f)
        step=$OPTARG
        ;;
        o)
        old_domain=$OPTARG
        ;;
        n)
        new_domain=$OPTARG
        ;;
        h)
        help
        exit 0
        ;;
        \?)
        echo "ERROR: 请输入参数"
        exit 1
        ;;
    esac
done

#部署节点配置文件检查
if [ ! -f "$coding_tool_dir/config.yaml" ];then
  echo "ERROR: config.yaml 文件不存在，请确认当前节点为coding rke部署节点"
  exit 1
fi

#DB连接检查
which mysql > /dev/null
if [ $? -ne 0 ];then
  echo "当前环境没有安装mysql客户端,尝试安装!"
  yum install mysql -y
  if [ $? -ne 0 ];then
    echo "安装mysql客户端失败"
    exit 1
  fi
fi

mysql -h$DB_HOST -u$DB_USER -p$DB_PASSWD -P$DB_PORT -e "status" > /dev/null
if [ $? -eq 0 ];then
  echo -e "\033[1;96mmysql 连接正常\033[0m"
  MYSQL_CONNECT="mysql -h $DB_HOST -u$DB_USER -p$DB_PASSWD -P$DB_PORT"
  echo "当前DB信息: $MYSQL_CONNECT"
else
  echo "mysql 连接异常!!!"
  exit 1
fi

#域名信息确认
echo -e "\033[0;92m当前需要替换的老域名为:\033[0m" $old_domain
echo -e "\033[0;93m当前需要替换的新域名为:\033[0m" $new_domain
if [ -z "$old_domain" ] || [ -z "$new_domain" ];then
  echo "error: 域名信息不能为空"
  exit 1
fi
read -p "确认替换[ ${new_domain} ]为主域名{yes/no}?" key
if [ "$key" = "yes" ];then
  read -p "替换将导致业务重启(-f search仅搜索不改变业务数据),请输入确认密码继续:" password
    auth_info=$(echo -n $password |base64)
    if [ "$auth_info" == "$token" ];then 
      echo -e "\033[0;94m开始执行>>>>>>>>>>>>>\033"
    else
      echo "密码错误,已退出!"
      exit 1
    fi
else
  echo "已退出"
  exit 1
fi

#日志
mkdir -p $coding_tool_dir/replace_domain
product_name="coding_replace_domain"
sys_log=$coding_tool_dir/replace_domain/$product_name\_$(date +\%Y-\%m-\%d).log
function log_info()
{
  message="[`hostname`]-[$(date +\%Y-\%m-\%d--\%H:\%M:\%S)]-[Info]-["message:" $1]"
  echo  "$message" >> $sys_log
  echo  "$message"

}

function log_warn()
{
  message="[`hostname`]-[$(date +\%Y-\%m-\%d--\%H:\%M:\%S)]-[Warn]-["message:" $1]"

  echo  "$message" >> $sys_log
  echo  "$message"
}

function log_error()
{
  message="[`hostname`]-[$(date +\%Y-\%m-\%d--\%H:\%M:\%S)]-[Error]-["message:" $1]"
  echo  "$message" >> $sys_log
  echo  "$message"
}


#全库全表搜索域名并生成更新sql
function search_mysql_info()
{
  > $coding_tool_dir/replace_domain/replace_domain_for_db_${record_date}.sql
  > $coding_tool_dir/replace_domain/search_domain_db_info_${record_date}.log
  db_list=$($MYSQL_CONNECT -e "show databases;"|egrep -wv 'test|information_schema|mysql|performance_schema|Database')
  log_info "数据库列表:" $db_list
  db_num=$(echo "$db_list"|wc -l)
  db_count=1
  for db_name in $db_list;
  do
      echo -e "\033[1;91m搜索DB进度:($db_num/$db_count) \033[0m"
      log_info "开始检查DB: "$db_name
      table_list=$($MYSQL_CONNECT -e "show tables from \`${db_name}\`" |grep -v Tables_in)
      table_num=$(echo "$table_list"|wc -l)
      table_count=1
      for tb_name in $table_list;
      do
          echo -e "\033[1;94m搜索table进度:($db_num/$db_count----$table_num/$table_count) \033[0m"
          log_info "开始检查table: "\n$tb_name
          field_list=$($MYSQL_CONNECT -e "desc \`$db_name\`.\`$tb_name\`"|grep -wv 'Field')
          #log_info "所有字段列表:$field_list"
          #varchar_field_list=$($MYSQL_CONNECT -e "desc \`$db_name\`.\`$tb_name\`"|grep -wv 'Field'|grep varchar|awk '{print $1}')
          choose_type_field_list=$(echo "$field_list"|egrep 'char|varchar|tinytext|text|longtext|mediumtext|set|enum'|awk '{print $1}')
          if [ -n "$choose_type_field_list" ];then
            #log_info "当前字符串字段列表:$choose_type_field_list"
            for field in $choose_type_field_list
            do
                search_result=$($MYSQL_CONNECT -e "select * from \`$db_name\`.\`$tb_name\` where \`$field\` like "\"%${old_domain}%"\" limit 0,1")
                if [ -n "$search_result" ];then
                  echo "db_name: $db_name  tb_name: $tb_name  field: $field" >> $coding_tool_dir/replace_domain/update_record_${record_date}.log
                  echo "$search_result" >> $coding_tool_dir/replace_domain/search_domain_db_info_${record_date}.log
                  echo "update \`$db_name\`.\`$tb_name\` set \`$field\` = REPLACE(\`$field\`, '$old_domain', '$new_domain');" >> $coding_tool_dir/replace_domain/replace_domain_for_db_${record_date}.sql
                  #sleep 5
                fi
            done 
          else
            log_warn "当前表查询结果为空"
          fi 
          table_count=`expr $table_count + 1`
      done
      db_count=`expr $db_count + 1`
  done
  log_info "生成的sql文件路径: $coding_tool_dir/replace_domain/replace_domain_for_db_${record_date}.sql"
}


function change_mysql_domain()
{
  db_list=$($MYSQL_CONNECT -e "show databases;"|egrep -wv 'test|information_schema|mysql|performance_schema|Database')
  db_num=$(echo "$db_list"|wc -l)
  db_count=1
  log_info "开始备份数据库"
  mkdir $coding_tool_dir/db_backup -p
  for db_name in $db_list;
  do
      echo -e "\033[47;35m备份进度:($db_num/$db_count) \033[0m"
      mysqldump -h$DB_HOST -u$DB_USER -p$DB_PASSWD -P$DB_PORT -B $db_name > $coding_tool_dir/db_backup/${db_name}_${record_date}.sql
      db_count=`expr $db_count + 1`
  done
  if [ $? -eq 0 ];then
    log_info "开始更新数据库"
    $MYSQL_CONNECT < $coding_tool_dir/replace_domain/replace_domain_for_db_${record_date}.sql
  else
    log_info "备份数据库失败"
    exit 1
  fi
}



function update_coredns()
{
  echo -e  "\033[41;30m 开始更新CoreDNS模块 \033[0m"
  helm template coredns -n kube-system --set private_domain="${new_domain}" "$coding_tool_dir/apps/coding-helm/charts/coredns/" -f $coding_tool_dir/apps/coding-helm/values.yaml | kubectl apply -f -
  kubectl -nkube-system rollout restart deploy coredns

}



function reinstall_coding_module()
{
  echo -e  "\033[41;30m 开始更新coding模块 \033[0m"
  sed -i "/^private_domain:/c\private_domain: ${new_domain}" $coding_tool_dir/config.yaml 
  cd $coding_tool_dir && ./install.sh -f coding
  if [ $? -eq 0 ];then
    log_info "部署coding成功,等待10秒后开始对deployment发起滚动更新"
    sleep 10
    deploy_list=$(kubectl -ncoding get deploy |grep -v NAME |awk '{print $1}')
    priority_start_model=(e-coding e-admin e-session e-scheduler entrance-gateway tengine)
    deploy_num=$(echo "$deploy_list"|wc -l)
    a1=1
    a2=1
    c=0
    for deployment_name in $deploy_list
    do
        kubectl -ncoding scale --replicas=0 deployment/$deployment_name
        b=$(( $a1 % 10 ))
        if [ $b = 0 ];then
          log_info "停止中,进度: ${deploy_num}/${a1},等待......."
          #sleep 1
        fi 
        a1=`expr $a1 + 1`
    done 
    for deployment_name in $deploy_list
    do
        if [[ ${priority_start_model[@]/${deployment_name}/} != ${priority_start_model[@]} ]];then
	  log_info "优先启动: $deployment_name"
          kubectl -ncoding scale --replicas=1 deployment/$deployment_name
          sleep 3
        else
          dp[$c]=$deployment_name
          c=`expr $c + 1`
        fi
    done
    for deployment_name in ${dp[@]}
    do
        b=$(( $a2 % 10 ))
        echo "启动:" $deployment_name
        kubectl -ncoding scale --replicas=1 deployment/$deployment_name
        if [ $b = 0 ];then
          #log_info "启动进度 ${deploy_num/${b2},等待......."
          log_info "启动进度 ${deploy_num}/${a2},等待....."
          sleep 1
        fi
        a2=`expr $a2 + 1`
    done
    log_info "滚动更新全部执行,等待pod状态全部running,大约2分钟"
    kubectl -ncoding get pod -o wide
    log_info "恭喜,变更完成,更换域名后请更新license许可!"
  else
    log_error "部署coding失败"
    exit 1
  fi
}


main()
{
  echo "step:" $step
  if [ "$step" = "all" ];then
    search_mysql_info
    sleep 10
    change_mysql_domain
    sleep 5
    update_coredns
    sleep 10
    reinstall_coding_module
  elif [ "$step" = "search" ];then
    search_mysql_info
  elif [ "$step" = "updatedb" ];then
    search_mysql_info
    change_mysql_domain
  elif [ "$step" = "updatecoredns" ];then
    update_coredns
  elif [ "$step" = "reinstall" ];then
    reinstall_coding_module
  elif [ -z "$step" ];then
    exit 0
  else
    echo "输入执行步骤有误"
    help
    exit 1
  fi

}

main


