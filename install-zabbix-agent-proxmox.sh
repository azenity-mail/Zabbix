#!/usr/bin/env bash
set -euo pipefail

# =========================
# Azenity - Zabbix Agent 2 Installer (Proxmox / Debian 13 trixie)
# Evidências: hostname, IP, data/hora, pacotes, serviço, porta e conectividade
# =========================

# --- Variáveis (override via environment) ---
ZBX_SERVER="${ZBX_SERVER:-172.20.7.58}"
ZBX_VERSION="${ZBX_VERSION:-7.4}"     # Repositório oficial Zabbix (ex.: 7.4)
LOG_DIR="${LOG_DIR:-/var/log/azenity}"
WORK_DIR="/tmp/azenity-zabbix.$$"

# --- Funções ---
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    log "ERRO: execute como root."
    exit 1
  fi
}

get_host() {
  hostname -f 2>/dev/null || hostname
}

get_primary_ip() {
  # Pega IP “de saída” (mais confiável em ambientes com múltiplas NICs)
  local ip
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {print $7; exit}')"
  if [ -n "${ip:-}" ]; then
    echo "$ip"
    return 0
  fi
  # fallback: primeiro IPv4 global
  ip -4 addr show scope global 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1
}

apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

set_kv() {
  # Atualiza ou adiciona "KEY=VALUE" no conf, lidando com linhas comentadas
  local key="$1" value="$2" file="$3"
  if grep -qE "^[#[:space:]]*${key}=" "$file"; then
    sed -i -E "s|^[#[:space:]]*${key}=.*|${key}=${value}|g" "$file"
  else
    echo "${key}=${value}" >> "$file"
  fi
}

tcp_test() {
  local host="$1" port="$2"
  if command -v timeout >/dev/null 2>&1; then
    timeout 3 bash -c "cat < /dev/null > /dev/tcp/${host}/${port}" >/dev/null 2>&1
  else
    # fallback sem timeout (pode demorar em rede ruim)
    bash -c "cat < /dev/null > /dev/tcp/${host}/${port}" >/dev/null 2>&1
  fi
}

# --- MAIN ---
require_root
mkdir -p "$LOG_DIR" "$WORK_DIR"

HOST="$(get_host)"
IP="$(get_primary_ip)"
TS="$(date '+%Y%m%d-%H%M%S')"
SAFE_HOST="${HOST//./_}"
LOG_FILE="${LOG_DIR}/ZabbixAgent2_${SAFE_HOST}_${IP:-NOIP}_${TS}.log"
TRANSCRIPT="${LOG_DIR}/ZabbixAgent2_${SAFE_HOST}_${IP:-NOIP}_${TS}.transcript.txt"

# Tudo que sai na tela vai pro log também
exec > >(tee -a "$LOG_FILE") 2>&1

log "==== ZABBIX AGENT 2 INSTALL - INÍCIO ===="
log "Host: ${HOST}"
log "IP:   ${IP:-NOIP}"
log "Data: $(date '+%Y-%m-%d %H:%M:%S')"
log "Zabbix Server: ${ZBX_SERVER}"
log "Zabbix Repo Version: ${ZBX_VERSION}"
log "Log: ${LOG_FILE}"

log "ETAPA 1 - Evidência do SO (/etc/os-release)"
if [ -f /etc/os-release ]; then
  cat /etc/os-release
else
  log "WARN: /etc/os-release não encontrado."
fi

log "ETAPA 2 - Pré-requisitos (curl/gnupg/lsb-release/ca-certificates)"
apt-get update -y
apt_install ca-certificates gnupg lsb-release curl

log "ETAPA 3 - Adicionar repositório oficial Zabbix (zabbix-release para Debian 13)"
RELEASE_DEB_URL="https://repo.zabbix.com/zabbix/${ZBX_VERSION}/release/debian/pool/main/z/zabbix-release/zabbix-release_latest_${ZBX_VERSION}+debian13_all.deb"
RELEASE_DEB_PATH="${WORK_DIR}/zabbix-release.deb"

log "Baixando: ${RELEASE_DEB_URL}"
curl -fsSL "${RELEASE_DEB_URL}" -o "${RELEASE_DEB_PATH}"
log "Arquivo baixado: ${RELEASE_DEB_PATH} (sha256 abaixo)"
sha256sum "${RELEASE_DEB_PATH}" || true

log "Instalando pacote de repositório (dpkg -i)"
dpkg -i "${RELEASE_DEB_PATH}"

log "apt-get update após adicionar repo"
apt-get update -y

log "ETAPA 4 - Instalar Zabbix Agent 2"
apt_install zabbix-agent2

log "ETAPA 5 - Configurar Agent 2 (Server/ServerActive/Hostname)"
CONF="/etc/zabbix/zabbix_agent2.conf"
if [ ! -f "$CONF" ]; then
  log "ERRO: arquivo $CONF não encontrado após instalação."
  exit 1
fi

cp -a "$CONF" "${CONF}.bak.${TS}"
log "Backup: ${CONF}.bak.${TS}"

set_kv "Server" "${ZBX_SERVER}" "$CONF"
set_kv "ServerActive" "${ZBX_SERVER}" "$CONF"
set_kv "Hostname" "${HOST}" "$CONF"

log "Trecho de evidência (linhas Server/ServerActive/Hostname):"
grep -nE "^(Server|ServerActive|Hostname)=" "$CONF" || true

log "ETAPA 6 - Habilitar e iniciar serviço"
systemctl enable --now zabbix-agent2

log "Evidência - status do serviço"
systemctl status zabbix-agent2 --no-pager || true

log "ETAPA 7 - Evidência de porta local (10050/tcp)"
if command -v ss >/dev/null 2>&1; then
  ss -lntp | awk 'NR==1 || /:10050/' || true
else
  netstat -lntp 2>/dev/null | awk 'NR==1 || /:10050/' || true
fi

log "ETAPA 8 - Teste de conectividade com o Zabbix Server"
log " - Active checks usam TCP/10051 (agente -> servidor)."
if tcp_test "${ZBX_SERVER}" 10051; then
  log "OK: Conectividade TCP ${ZBX_SERVER}:10051 (active) = SUCESSO"
else
  log "WARN: Falha TCP ${ZBX_SERVER}:10051 (active). Verifique rota/firewall/rede."
fi

log " - Passive checks usam TCP/10050 (servidor -> agente)."
log "   OBS: esse teste deve ser validado do lado do servidor (zabbix_get ou item passivo)."

log "ETAPA 9 - Evidência de versão/pacotes"
dpkg -l | egrep -i 'zabbix-agent2|zabbix-release' || true
zabbix_agent2 -V || true

log "Limpando temporários"
rm -rf "$WORK_DIR" || true

log "==== ZABBIX AGENT 2 INSTALL - FIM (SUCESSO) ===="
log "LOG FINAL: ${LOG_FILE}"
