#!/bin/bash

# Secure WireGuard server installer
# https://github.com/angristan/wireguard-install

RED='\033[0;31m'
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'

SERVER_WG_NIC="wg0"
SERVER_WG_IPV4="10.66.66.1"
SERVER_WG_IPV6="fd42:42:42::1"
CLIENT_WG_IPV4="10.66.66.2"
CLIENT_WG_IPV6="fd42:42:42::2"
CLIENT_DNS_1="1.1.1.1"
CLIENT_DNS_2="2606:4700:4700::1111"
ALLOWED_IPS="0.0.0.0/0,::/0"
CLIENT_CONFIG_NAME="${SERVER_WG_NIC}-client.conf"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT_CHECK_SCRIPT="${SCRIPT_DIR}/wireguard-port-check.sh"

function installPackages() {
	if ! "$@"; then
		echo -e "${RED}Failed to install packages.${NC}"
		echo "Please check your internet connection and package sources."
		exit 1
	fi
}

function waitForCloudInit() {
	if command -v cloud-init &>/dev/null; then
		echo "Waiting for cloud-init to finish..."
		if ! cloud-init status --wait; then
			echo -e "${ORANGE}cloud-init status check failed. Continuing with package manager lock waits.${NC}"
		fi
	fi
}

function aptGet() {
	apt-get -o DPkg::Lock::Timeout=600 "$@"
}

function runPortCheck() {
	if [[ ! -f ${PORT_CHECK_SCRIPT} ]]; then
		echo -e "${RED}Port check script not found: ${PORT_CHECK_SCRIPT}${NC}"
		echo "Download wireguard-port-check.sh into the same directory as wireguard-install.sh before running this installer."
		exit 1
	fi

	if [[ ! -r ${PORT_CHECK_SCRIPT} ]]; then
		echo -e "${RED}Port check script is not readable: ${PORT_CHECK_SCRIPT}${NC}"
		exit 1
	fi

	if ! bash "${PORT_CHECK_SCRIPT}"; then
		echo -e "${RED}WireGuard port audit failed.${NC}"
		exit 1
	fi
}

function isRoot() {
	if [ "${EUID}" -ne 0 ]; then
		echo "You need to run this script as root"
		exit 1
	fi
}

function checkVirt() {
	if command -v virt-what &>/dev/null; then
		VIRT=$(virt-what)
	else
		VIRT=$(systemd-detect-virt)
	fi
	if [[ ${VIRT} == "openvz" ]]; then
		echo "OpenVZ is not supported"
		exit 1
	fi
	if [[ ${VIRT} == "lxc" ]]; then
		echo "LXC is not supported (yet)."
		echo "WireGuard can technically run in an LXC container,"
		echo "but the kernel module has to be installed on the host,"
		echo "the container has to be run with some specific parameters"
		echo "and only the tools need to be installed in the container."
		exit 1
	fi
}

function checkOS() {
	# shellcheck source=/dev/null
	source /etc/os-release
	OS="${ID}"
	if [[ ${OS} == "debian" || ${OS} == "raspbian" ]]; then
		if [[ ${VERSION_ID} -lt 10 ]]; then
			echo "Your version of Debian (${VERSION_ID}) is not supported. Please use Debian 10 Buster or later"
			exit 1
		fi
		OS=debian # overwrite if raspbian
	elif [[ ${OS} == "ubuntu" ]]; then
		RELEASE_YEAR=$(echo "${VERSION_ID}" | cut -d'.' -f1)
		if [[ ${RELEASE_YEAR} -lt 18 ]]; then
			echo "Your version of Ubuntu (${VERSION_ID}) is not supported. Please use Ubuntu 18.04 or later"
			exit 1
		fi
	elif [[ ${OS} == "fedora" ]]; then
		if [[ ${VERSION_ID} -lt 32 ]]; then
			echo "Your version of Fedora (${VERSION_ID}) is not supported. Please use Fedora 32 or later"
			exit 1
		fi
	elif [[ ${OS} == 'centos' ]] || [[ ${OS} == 'almalinux' ]] || [[ ${OS} == 'rocky' ]]; then
		if [[ ${VERSION_ID} == 7* ]]; then
			echo "Your version of CentOS (${VERSION_ID}) is not supported. Please use CentOS 8 or later"
			exit 1
		fi
	elif [[ -e /etc/oracle-release ]]; then
		# shellcheck source=/dev/null
		source /etc/os-release
		OS=oracle
	elif [[ -e /etc/arch-release ]]; then
		OS=arch
	elif [[ -e /etc/alpine-release ]]; then
		OS=alpine
		if ! command -v virt-what &>/dev/null; then
			if ! (apk update && apk add virt-what); then
				echo -e "${RED}Failed to install virt-what. Continuing without virtualization check.${NC}"
			fi
		fi
	else
		echo "Looks like you aren't running this installer on a Debian, Ubuntu, Fedora, CentOS, AlmaLinux, Oracle or Arch Linux system"
		exit 1
	fi
}

function getClientConfigDir() {
	echo "/root"
}

function checkExistingWireGuardConfig() {
	local CLIENT_CONFIG_FILE
	local CONFIG_FILE

	CLIENT_CONFIG_FILE="$(getClientConfigDir)/${CLIENT_CONFIG_NAME}"

	for CONFIG_FILE in /etc/wireguard/params "/etc/wireguard/${SERVER_WG_NIC}.conf" "${CLIENT_CONFIG_FILE}"; do
		if [[ -e ${CONFIG_FILE} ]]; then
			echo -e "${RED}Existing WireGuard configuration found: ${CONFIG_FILE}${NC}"
			echo "This installer creates one server and one client only. Remove or back up the existing configuration before running it again."
			exit 1
		fi
	done
}

function initialCheck() {
	isRoot
	checkExistingWireGuardConfig
	checkOS
	checkVirt
}

function setDefaultConfig() {
	echo "Welcome to the WireGuard installer!"
	echo "The git repository is available at: https://github.com/cuimingda/wireguard-toolbox"
	echo ""
	echo "Running non-interactive setup with default values."

	SERVER_PUB_IP=$(ip -4 addr | sed -ne 's|^.* inet \([^/]*\)/.* scope global.*$|\1|p' | awk '{print $1}' | head -1)
	if [[ -z ${SERVER_PUB_IP} ]]; then
		SERVER_PUB_IP=$(ip -6 addr | sed -ne 's|^.* inet6 \([^/]*\)/.* scope global.*$|\1|p' | head -1)
	fi

	if [[ -z ${SERVER_PUB_IP} ]]; then
		echo -e "${RED}Could not detect a public IPv4 or IPv6 address.${NC}"
		exit 1
	fi

	SERVER_PUB_NIC="$(ip -4 route list default 2>/dev/null | awk '/dev/ {for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1)}' | head -1)"
	if [[ -z ${SERVER_PUB_NIC} ]]; then
		SERVER_PUB_NIC="$(ip -6 route list default 2>/dev/null | awk '/dev/ {for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1)}' | head -1)"
	fi

	if [[ ! ${SERVER_PUB_NIC} =~ ^[a-zA-Z0-9_]+$ ]]; then
		echo -e "${RED}Could not detect a valid public network interface.${NC}"
		exit 1
	fi

	SERVER_PORT=$(shuf -i49152-65535 -n1)

	echo ""
	echo "Detected public address: ${SERVER_PUB_IP}"
	echo "Detected public interface: ${SERVER_PUB_NIC}"
	echo "WireGuard interface: ${SERVER_WG_NIC}"
	echo "Client configuration file: $(getClientConfigDir)/${CLIENT_CONFIG_NAME}"
	echo ""
}

function installWireGuard() {
	setDefaultConfig

	# Install WireGuard tools and module
	if [[ ${OS} == 'ubuntu' ]] || [[ ${OS} == 'debian' && ${VERSION_ID} -gt 10 ]]; then
		waitForCloudInit
		installPackages aptGet update
		installPackages aptGet install -y wireguard iptables resolvconf qrencode
	elif [[ ${OS} == 'debian' ]]; then
		waitForCloudInit
		if ! grep -rqs "^deb .* buster-backports" /etc/apt/; then
			echo "deb http://deb.debian.org/debian buster-backports main" >/etc/apt/sources.list.d/backports.list
			installPackages aptGet update
		fi
		installPackages aptGet update
		installPackages aptGet install -y iptables resolvconf qrencode
		installPackages aptGet install -y -t buster-backports wireguard
	elif [[ ${OS} == 'fedora' ]]; then
		if [[ ${VERSION_ID} -lt 32 ]]; then
			installPackages dnf install -y dnf-plugins-core
			dnf copr enable -y jdoss/wireguard
			installPackages dnf install -y wireguard-dkms
		fi
		installPackages dnf install -y wireguard-tools iptables qrencode
	elif [[ ${OS} == 'centos' ]] || [[ ${OS} == 'almalinux' ]] || [[ ${OS} == 'rocky' ]]; then
		if [[ ${VERSION_ID} == 8* ]]; then
			installPackages yum install -y epel-release elrepo-release
			installPackages yum install -y kmod-wireguard
			yum install -y qrencode || true # not available on release 9
		fi
		installPackages yum install -y wireguard-tools iptables
	elif [[ ${OS} == 'oracle' ]]; then
		installPackages dnf install -y oraclelinux-developer-release-el8
		dnf config-manager --disable -y ol8_developer
		dnf config-manager --enable -y ol8_developer_UEKR6
		dnf config-manager --save -y --setopt=ol8_developer_UEKR6.includepkgs='wireguard-tools*'
		installPackages dnf install -y wireguard-tools qrencode iptables
	elif [[ ${OS} == 'arch' ]]; then
		installPackages pacman -S --needed --noconfirm wireguard-tools qrencode
	elif [[ ${OS} == 'alpine' ]]; then
		apk update
		installPackages apk add wireguard-tools iptables libqrencode-tools
	fi

	# Verify WireGuard installation
	if ! command -v wg &>/dev/null; then
		echo -e "${RED}WireGuard installation failed. The 'wg' command was not found.${NC}"
		echo "Please check the installation output above for errors."
		exit 1
	fi

	# Make sure the directory exists (this does not seem the be the case on fedora)
	mkdir /etc/wireguard >/dev/null 2>&1

	chmod 600 -R /etc/wireguard/

	SERVER_PRIV_KEY=$(wg genkey)
	SERVER_PUB_KEY=$(echo "${SERVER_PRIV_KEY}" | wg pubkey)

	# Save WireGuard settings
	echo "SERVER_PUB_IP=${SERVER_PUB_IP}
SERVER_PUB_NIC=${SERVER_PUB_NIC}
SERVER_WG_NIC=${SERVER_WG_NIC}
SERVER_WG_IPV4=${SERVER_WG_IPV4}
SERVER_WG_IPV6=${SERVER_WG_IPV6}
SERVER_PORT=${SERVER_PORT}
SERVER_PRIV_KEY=${SERVER_PRIV_KEY}
SERVER_PUB_KEY=${SERVER_PUB_KEY}
CLIENT_DNS_1=${CLIENT_DNS_1}
CLIENT_DNS_2=${CLIENT_DNS_2}
ALLOWED_IPS=${ALLOWED_IPS}" >/etc/wireguard/params

	# Add server interface
	echo "[Interface]
Address = ${SERVER_WG_IPV4}/24,${SERVER_WG_IPV6}/64
ListenPort = ${SERVER_PORT}
PrivateKey = ${SERVER_PRIV_KEY}" >"/etc/wireguard/${SERVER_WG_NIC}.conf"

	if pgrep firewalld; then
		FIREWALLD_IPV4_ADDRESS=$(echo "${SERVER_WG_IPV4}" | cut -d"." -f1-3)".0"
		FIREWALLD_IPV6_ADDRESS="${SERVER_WG_IPV6%:*}:0"
		echo "PostUp = firewall-cmd --zone=public --add-interface=${SERVER_WG_NIC} && firewall-cmd --add-port ${SERVER_PORT}/udp && firewall-cmd --add-rich-rule='rule family=ipv4 source address=${FIREWALLD_IPV4_ADDRESS}/24 masquerade' && firewall-cmd --add-rich-rule='rule family=ipv6 source address=${FIREWALLD_IPV6_ADDRESS}/24 masquerade'
PostDown = firewall-cmd --zone=public --add-interface=${SERVER_WG_NIC} && firewall-cmd --remove-port ${SERVER_PORT}/udp && firewall-cmd --remove-rich-rule='rule family=ipv4 source address=${FIREWALLD_IPV4_ADDRESS}/24 masquerade' && firewall-cmd --remove-rich-rule='rule family=ipv6 source address=${FIREWALLD_IPV6_ADDRESS}/24 masquerade'" >>"/etc/wireguard/${SERVER_WG_NIC}.conf"
	else
		echo "PostUp = iptables -I INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT
PostUp = iptables -I FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -j ACCEPT
PostUp = iptables -I FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE
PostUp = ip6tables -I FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
PostUp = ip6tables -t nat -A POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE
PostDown = iptables -D INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT
PostDown = iptables -D FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -j ACCEPT
PostDown = iptables -D FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE
PostDown = ip6tables -D FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
PostDown = ip6tables -t nat -D POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE" >>"/etc/wireguard/${SERVER_WG_NIC}.conf"
	fi

	# Enable routing on the server
	echo "net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1" >/etc/sysctl.d/wg.conf

	if [[ ${OS} == 'fedora' ]]; then
		chmod -v 700 /etc/wireguard
		chmod -v 600 /etc/wireguard/*
	fi

	if [[ ${OS} == 'alpine' ]]; then
		sysctl -p /etc/sysctl.d/wg.conf
		rc-update add sysctl
		ln -s /etc/init.d/wg-quick "/etc/init.d/wg-quick.${SERVER_WG_NIC}"
		rc-service "wg-quick.${SERVER_WG_NIC}" start
		rc-update add "wg-quick.${SERVER_WG_NIC}"
	else
		sysctl --system

		systemctl start "wg-quick@${SERVER_WG_NIC}"
		systemctl enable "wg-quick@${SERVER_WG_NIC}"
	fi

	createClientConfig

	# Check if WireGuard is running
	if [[ ${OS} == 'alpine' ]]; then
		rc-service --quiet "wg-quick.${SERVER_WG_NIC}" status
	else
		systemctl is-active --quiet "wg-quick@${SERVER_WG_NIC}"
	fi
	WG_RUNNING=$?

	# WireGuard might not work if we updated the kernel. Tell the user to reboot
	if [[ ${WG_RUNNING} -ne 0 ]]; then
		echo -e "\n${RED}WARNING: WireGuard does not seem to be running.${NC}"
		if [[ ${OS} == 'alpine' ]]; then
			echo -e "${ORANGE}You can check if WireGuard is running with: rc-service wg-quick.${SERVER_WG_NIC} status${NC}"
		else
			echo -e "${ORANGE}You can check if WireGuard is running with: systemctl status wg-quick@${SERVER_WG_NIC}${NC}"
		fi
		echo -e "${ORANGE}If you get something like \"Cannot find device ${SERVER_WG_NIC}\", please reboot!${NC}"
	else # WireGuard is running
		echo -e "\n${GREEN}WireGuard is running.${NC}"
		if [[ ${OS} == 'alpine' ]]; then
			echo -e "${GREEN}You can check the status of WireGuard with: rc-service wg-quick.${SERVER_WG_NIC} status\n\n${NC}"
		else
			echo -e "${GREEN}You can check the status of WireGuard with: systemctl status wg-quick@${SERVER_WG_NIC}\n\n${NC}"
		fi
		echo -e "${ORANGE}If you don't have internet connectivity from your client, try to reboot the server.${NC}"
	fi

	runPortCheck
}

function createClientConfig() {
	# If SERVER_PUB_IP is IPv6, add brackets if missing
	if [[ ${SERVER_PUB_IP} =~ .*:.* ]]; then
		if [[ ${SERVER_PUB_IP} != *"["* ]] || [[ ${SERVER_PUB_IP} != *"]"* ]]; then
			SERVER_PUB_IP="[${SERVER_PUB_IP}]"
		fi
	fi
	ENDPOINT="${SERVER_PUB_IP}:${SERVER_PORT}"

	# Generate key pair for the client
	CLIENT_PRIV_KEY=$(wg genkey)
	CLIENT_PUB_KEY=$(echo "${CLIENT_PRIV_KEY}" | wg pubkey)
	CLIENT_PRE_SHARED_KEY=$(wg genpsk)

	HOME_DIR=$(getClientConfigDir)
	CLIENT_CONFIG_FILE="${HOME_DIR}/${CLIENT_CONFIG_NAME}"

	# Create client file and add the server as a peer
	echo "[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = ${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128
DNS = ${CLIENT_DNS_1}, ${CLIENT_DNS_2}

# Uncomment the next line to set a custom MTU
# This might impact performance, so use it only if you know what you are doing
# See https://github.com/nitred/nr-wg-mtu-finder to find your optimal MTU
# MTU = 1420

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
Endpoint = ${ENDPOINT}
AllowedIPs = ${ALLOWED_IPS}" >"${CLIENT_CONFIG_FILE}"

	# Add the client as a peer to the server
	echo -e "\n### Client ${SERVER_WG_NIC}
[Peer]
PublicKey = ${CLIENT_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
AllowedIPs = ${CLIENT_WG_IPV4}/32,${CLIENT_WG_IPV6}/128" >>"/etc/wireguard/${SERVER_WG_NIC}.conf"

	wg syncconf "${SERVER_WG_NIC}" <(wg-quick strip "${SERVER_WG_NIC}")

	# Generate QR code if qrencode is installed
	if command -v qrencode &>/dev/null; then
		echo -e "${GREEN}\nHere is your client config file as a QR Code:\n${NC}"
		qrencode -t ansiutf8 -l L <"${CLIENT_CONFIG_FILE}"
		echo ""
	fi

	echo -e "${GREEN}Your client config file is in ${CLIENT_CONFIG_FILE}${NC}"
	echo "Endpoint = ${ENDPOINT}"
}

# Check for root, virt, OS...
initialCheck

installWireGuard
