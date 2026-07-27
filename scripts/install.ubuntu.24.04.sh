#!/bin/bash

# Author
# original author:https://github.com/gongzili456
# modified by:https://github.com/haoel
# fixed for Ubuntu 24.04

# Ubuntu 24.04 系统环境

COLOR_ERROR="\e[38;5;198m"
COLOR_NONE="\e[0m"
COLOR_SUCC="\e[92m"

update_core(){
    echo -e "${COLOR_ERROR}当前系统内核版本太低 <$VERSION_CURR>, 需要更新系统内核.${COLOR_NONE}"
    echo -e "${COLOR_ERROR}注意：Ubuntu 24.04 默认内核已满足要求。如果您的系统内核极低，请手动升级内核。${COLOR_NONE}"
    exit 1
}

check_bbr(){
    has_bbr=$(lsmod | grep bbr)

    # 如果已经发现 bbr 进程
    if [ -n "$has_bbr" ] ;then
        echo -e "${COLOR_SUCC}TCP BBR 拥塞控制算法已经启动${COLOR_NONE}"
    else
        start_bbr
    fi
}

start_bbr(){
    echo "启动 TCP BBR 拥塞控制算法"
    sudo modprobe tcp_bbr
    echo "tcp_bbr" | sudo tee /etc/modules-load.d/bbr.conf
    echo "net.core.default_qdisc=fq" | sudo tee /etc/sysctl.d/99-bbr.conf
    echo "net.ipv4.tcp_congestion_control=bbr" | sudo tee -a /etc/sysctl.d/99-bbr.conf
    sudo sysctl --system
    sysctl net.ipv4.tcp_available_congestion_control
    sysctl net.ipv4.tcp_congestion_control
}

install_bbr() {
    # 比较版本号 (修复多位数时的版本号对比问题)
    if [ "$(printf '%s\n' "$VERSION_MIN" "$VERSION_CURR" | sort -V | head -n1)" = "$VERSION_MIN" ]; then
        check_bbr
    else
        update_core
    fi
}

install_docker() {
    if ! [ -x "$(command -v docker)" ]; then
        echo "开始安装 Docker CE"
        sudo apt-get update -qq
        sudo apt-get install -y ca-certificates curl
        sudo install -m 0755 -d /etc/apt/keyrings
        sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        sudo chmod a+r /etc/apt/keyrings/docker.asc

        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
          $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
          sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

        sudo apt-get update -qq
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io
    else
        echo -e "${COLOR_SUCC}Docker CE 已经安装成功了${COLOR_NONE}"
    fi
}

check_container(){
    # 修复精准匹配问题，防止 gost 与 gost-trojan 混淆
    has_container=$(sudo docker ps -a --format "{{.Names}}" | grep -w "^$1$")

    if [ -n "$has_container" ] ;then
        return 0
    else
        return 1
    fi
}

install_certbot() {
    echo "开始通过 Snap 安装 certbot 命令行工具"
    sudo apt-get update -qq
    sudo apt-get install -y snapd
    sudo snap install core
    sudo snap refresh core
    sudo snap install --classic certbot
    
    if [ ! -f /usr/bin/certbot ]; then
        sudo ln -s /snap/bin/certbot /usr/bin/certbot
    fi
}

create_cert() {
    if ! [ -x "$(command -v certbot)" ]; then
        install_certbot
    fi

    echo "开始生成 SSL 证书"
    echo -e "${COLOR_ERROR}注意：生成证书前,需要将域名指向一个有效的 IP,否则无法创建证书.${COLOR_NONE}"
    read -r -p "是否已经将域名指向了 IP？[Y/n]" has_record

    if ! [[ "$has_record" = "Y" || "$has_record" = "y" ]] ;then
        echo "请操作完成后再继续."
        return
    fi

    read -r -p "请输入你要使用的域名:" domain

    sudo certbot certonly --standalone -d "${domain}"
}

install_gost_http2() {
    if ! [ -x "$(command -v docker)" ]; then
        echo -e "${COLOR_ERROR}未发现Docker，请求安装 Docker ! ${COLOR_NONE}"
        return
    fi

    if check_container gost-http2 ; then
        echo -e "${COLOR_ERROR}Gost (HTTP2) 容器已经在运行了，你可以手动停止容器，并删除容器，然后再执行本命令来重新安装 Gost。 ${COLOR_NONE}"
        return
    fi

    echo "准备启动 Gost 代理程序,为了安全,需要使用用户名与密码进行认证."
    read -r -p "请输入你要使用的域名：" DOMAIN
    read -r -p "请输入你要使用的用户名:" USER
    read -r -p "请输入你要使用的密码:" PASS
    read -r -p "请输入HTTP/2需要侦听的端口号(443)：" PORT

    if [[ -z "${PORT// }" ]] || ! [[ "${PORT}" =~ ^[0-9]+$ ]] || ! { [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; }; then
        echo -e "${COLOR_ERROR}非法端口,使用默认端口 443 !${COLOR_NONE}"
        PORT=443
    fi

    BIND_IP=0.0.0.0
    CERT_DIR=/etc/letsencrypt
    CERT=${CERT_DIR}/live/${DOMAIN}/fullchain.pem
    KEY=${CERT_DIR}/live/${DOMAIN}/privkey.pem

    sudo docker run -d --name gost-http2 \
        --restart=always \
        -v ${CERT_DIR}:${CERT_DIR}:ro \
        --net=host ginuerzh/gost \
        -L "http2://${USER}:${PASS}@${BIND_IP}:${PORT}?cert=${CERT}&key=${KEY}&probe_resist=code:400&knock=www.google.com"
}

install_trojan_go() {
    if ! [ -x "$(command -v docker)" ]; then
        echo -e "${COLOR_ERROR}未发现Docker，请求安装 Docker ! ${COLOR_NONE}"
        return
    fi

    if check_container trojan-go ; then
        echo -e "${COLOR_ERROR}Trojan-Go 容器已经在运行了，你可以手动停止容器，并删除容器，然后再执行本命令来重新安装 Trojan-Go。 ${COLOR_NONE}"
        return
    fi

    echo "准备启动 Trojan-Go 代理程序,为了安全,需要使用密码进行认证."
    read -r -p "请输入你要使用的域名：" DOMAIN
    read -r -p "请输入你要使用的密码:" PASS
    read -r -p "请输入Trojan需要侦听的端口号(9527)：" PORT

    if [[ -z "${PORT// }" ]] || ! [[ "${PORT}" =~ ^[0-9]+$ ]] || ! { [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; }; then
        echo -e "${COLOR_ERROR}非法端口,使用默认端口 9527 !${COLOR_NONE}"
        PORT=9527
    fi

    CERT_DIR=/etc/letsencrypt
    CERT=${CERT_DIR}/live/${DOMAIN}/fullchain.pem
    KEY=${CERT_DIR}/live/${DOMAIN}/privkey.pem

    sudo mkdir -p /etc/trojan-go
    sudo tee /etc/trojan-go/config.json > /dev/null <<EOF
{
    "run_type": "server",
    "local_addr": "0.0.0.0",
    "local_port": ${PORT},
    "remote_addr": "www.google.com",
    "remote_port": 80,
    "password": [
        "${PASS}"
    ],
    "ssl": {
        "cert": "${CERT}",
        "key": "${KEY}"
    }
}
EOF

    sudo docker run -d --name trojan-go \
        --restart=always \
        --net=host \
        -v /etc/trojan-go/config.json:/etc/trojan-go/config.json \
        -v ${CERT_DIR}:${CERT_DIR}:ro \
        teddysun/trojan-go
}

crontab_exists() {
    sudo crontab -l 2>/dev/null | grep -F "$1" >/dev/null 2>/dev/null
}

create_cron_job(){
    # 写入前先检查，避免重复任务。使用更为稳妥的 crontab 操作
    if ! crontab_exists "certbot renew --force-renewal"; then
        (sudo crontab -l 2>/dev/null; echo "0 0 1 * * /usr/bin/certbot renew --force-renewal") | sudo crontab -
        echo -e "${COLOR_SUCC}成功安装证书renew定时作业！${COLOR_NONE}"
    else
        echo -e "${COLOR_SUCC}证书renew定时作业已经安装过！${COLOR_NONE}"
    fi

    if ! crontab_exists "docker restart gost-http2 trojan-go"; then
        (sudo crontab -l 2>/dev/null; echo "5 0 1 * * /usr/bin/docker restart gost-http2 trojan-go >/dev/null 2>&1") | sudo crontab -
        echo -e "${COLOR_SUCC}成功安装gost更新证书定时作业！${COLOR_NONE}"
    else
        echo -e "${COLOR_SUCC}gost更新证书定时作业已经成功安装过！${COLOR_NONE}"
    fi
}

install_shadowsocks(){
    if ! [ -x "$(command -v docker)" ]; then
        echo -e "${COLOR_ERROR}未发现Docker，请求安装 Docker ! ${COLOR_NONE}"
        return
    fi

    if check_container ss ; then
        echo -e "${COLOR_ERROR}ShadowSocks 容器已经在运行了，你可以手动停止容器，并删除容器，然后再执行本命令来重新安装 ShadowSocks。${COLOR_NONE}"
        return
    fi

    echo "准备启动 ShadowSocks 代理程序,为了安全,需要使用用户名与密码进行认证."
    read -r -p "请输入你要使用的密码:" PASS
    read -r -p "请输入ShadowSocks需要侦听的端口号(1984)：" PORT

    BIND_IP=0.0.0.0

    if [[ -z "${PORT// }" ]] || ! [[ "${PORT}" =~ ^[0-9]+$ ]] || ! { [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; }; then
        echo -e "${COLOR_ERROR}非法端口,使用默认端口 1984 !${COLOR_NONE}"
        PORT=1984
    fi

    sudo docker run -dt --name ss \
        --restart=always \
        -p "${PORT}:${PORT}" mritd/shadowsocks \
        -s "-s ${BIND_IP} -p ${PORT} -m aes-256-cfb -k ${PASS} --fast-open"
}

install_vpn(){
    if ! [ -x "$(command -v docker)" ]; then
        echo -e "${COLOR_ERROR}未发现Docker，请求安装 Docker ! ${COLOR_NONE}"
        return
    fi

    if check_container vpn ; then
        echo -e "${COLOR_ERROR}VPN 容器已经在运行了，你可以手动停止容器，并删除容器，然后再执行本命令来重新安装 VPN。${COLOR_NONE}"
        return
    fi

    echo "准备启动 VPN/L2TP 代理程序,为了安全,需要使用用户名与密码进行认证."
    read -r -p "请输入你要使用的用户名:" USER
    read -r -p "请输入你要使用的密码:" PASS
    read -r -p "请输入你要使用的PSK Key:" PSK

    sudo docker run -d --name vpn --privileged \
        --restart=always \
        -e PSK="${PSK}" \
        -e USERNAME="${USER}" -e PASSWORD="${PASS}" \
        -p 500:500/udp \
        -p 4500:4500/udp \
        -p 1701:1701/tcp \
        -p 1194:1194/udp  \
        siomiz/softethervpn
}

install_brook(){
    echo -e "${COLOR_ERROR}Brook 原第三方安装脚本已失效，建议直接下载官方 release 版本或使用 Docker 安装。${COLOR_NONE}"
    echo "如需继续，请手动查阅官方项目：https://github.com/txthinking/brook"
}

# TODO: install v2ray

init(){
    VERSION_CURR=$(uname -r | awk -F '-' '{print $1}')
    VERSION_MIN="4.9.0"

    OIFS=$IFS  # Save the current IFS (Internal Field Separator)
    IFS=','    # New IFS

    COLUMNS=50
    echo -e "\n菜单选项\n"

    while true
    do
        PS3="Please select a option:"
        re='^[0-9]+$'
        select opt in "安装 TCP BBR 拥塞控制算法" \
                    "安装 Docker 服务程序" \
                    "创建 SSL 证书" \
                    "安装 Gost HTTP/2 代理服务" \
                    "安装 ShadowSocks 代理服务" \
                    "安装 VPN/L2TP 服务" \
                    "安装 Brook 代理服务" \
                    "安装 Trojan-Go 服务" \
                    "创建证书更新 CronJob" \
                    "退出" ; do

            if ! [[ $REPLY =~ $re ]] ; then
                echo -e "${COLOR_ERROR}Invalid option. Please input a number.${COLOR_NONE}"
                break;
            elif (( REPLY == 1 )) ; then
                install_bbr
                break;
            elif (( REPLY == 2 )) ; then
                install_docker
                break
            elif (( REPLY == 3 )) ; then
                create_cert
                #loop=1
                break
            elif (( REPLY == 4 )) ; then
                install_gost_http2
                break
            elif (( REPLY == 5  )) ; then
                install_shadowsocks
                break
            elif (( REPLY == 6 )) ; then
                install_vpn
                break
            elif (( REPLY == 7 )) ; then
                install_brook
                break
            elif (( REPLY == 8 )) ; then
                install_trojan_go
                break
            elif (( REPLY == 9 )) ; then
                create_cron_job
                break
            elif (( REPLY == 10 )) ; then
                exit
            else
                echo -e "${COLOR_ERROR}Invalid option. Try another one.${COLOR_NONE}"
            fi
        done
    done

    echo "${opt}"
    IFS=$OIFS  # Restore the IFS
}

init
