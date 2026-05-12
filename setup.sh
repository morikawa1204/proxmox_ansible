#!/usr/bin/env bash
# setup.sh — 初回セットアップウィザード
# 実行: bash setup.sh
set -euo pipefail

VAULT_FILE="inventory/group_vars/vault.yml"
VAULT_PASS_FILE=".vault_pass"
ANSIBLE_CFG="ansible.cfg"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo ""
echo "=================================================="
echo "  Proxmox Ansible K8s Cluster — 初回セットアップ"
echo "=================================================="
echo ""

# --- 前提チェック ---
command -v ansible >/dev/null 2>&1 || { echo -e "${RED}ERROR: ansible がインストールされていません${NC}"; exit 1; }
command -v ansible-vault >/dev/null 2>&1 || { echo -e "${RED}ERROR: ansible-vault が見つかりません${NC}"; exit 1; }

ANSIBLE_VERSION=$(ansible --version | head -1 | grep -oP '\d+\.\d+' | head -1)
REQUIRED="2.15"
if ! awk "BEGIN{exit !($ANSIBLE_VERSION >= $REQUIRED)}"; then
  echo -e "${RED}ERROR: Ansible ${REQUIRED}+ が必要です (現在: ${ANSIBLE_VERSION})${NC}"
  exit 1
fi

# --- vault.yml 作成 ---
if [ -f "$VAULT_FILE" ]; then
  echo -e "${YELLOW}SKIP: ${VAULT_FILE} は既に存在します${NC}"
else
  echo -e "${GREEN}[1/5] vault.yml を作成します${NC}"
  cp inventory/group_vars/vault.yml.example "$VAULT_FILE"

  echo ""
  read -rp "  Proxmox root パスワード: " PROXMOX_PASS
  read -rp "  VM ユーザー (k8s) パスワード: " VM_PASS
  echo "  SSH 公開鍵を入力してください (例: ssh-ed25519 AAAA...):"
  read -rp "  > " SSH_PUBKEY

  sed -i "s|YOUR_PROXMOX_PASSWORD|${PROXMOX_PASS}|" "$VAULT_FILE"
  sed -i "s|YOUR_VM_PASSWORD|${VM_PASS}|" "$VAULT_FILE"
  sed -i "s|ssh-ed25519 AAAA... your-key@host|${SSH_PUBKEY}|" "$VAULT_FILE"
  echo ""
fi

# --- vault パスワード設定 ---
if [ -f "$VAULT_PASS_FILE" ]; then
  echo -e "${YELLOW}SKIP: ${VAULT_PASS_FILE} は既に存在します${NC}"
else
  echo -e "${GREEN}[2/5] Ansible Vault パスワードを設定します${NC}"
  read -rsp "  Vault パスワード (暗号化キー): " VAULT_PASSWORD
  echo ""
  echo "$VAULT_PASSWORD" > "$VAULT_PASS_FILE"
  chmod 600 "$VAULT_PASS_FILE"
  ansible-vault encrypt "$VAULT_FILE"
  echo -e "  ${GREEN}✓ vault.yml を暗号化しました${NC}"
fi

# --- SSH 秘密鍵パス設定 ---
echo ""
echo -e "${GREEN}[3/5] SSH 秘密鍵パスを設定します${NC}"
DEFAULT_KEY="$HOME/.ssh/id_ed25519"
read -rp "  SSH 秘密鍵のパス [${DEFAULT_KEY}]: " KEY_PATH
KEY_PATH="${KEY_PATH:-$DEFAULT_KEY}"

if [ ! -f "$KEY_PATH" ]; then
  echo -e "${RED}  WARNING: ${KEY_PATH} が見つかりません。ansible.cfg は書き換えますが確認してください${NC}"
fi

# OS 判定して sed を切り替え
if sed --version 2>/dev/null | grep -q GNU; then
  sed -i "s|private_key_file = .*|private_key_file = ${KEY_PATH}|" "$ANSIBLE_CFG"
else
  sed -i '' "s|private_key_file = .*|private_key_file = ${KEY_PATH}|" "$ANSIBLE_CFG"
fi
echo -e "  ${GREEN}✓ ansible.cfg を更新しました${NC}"

# --- Ansible Galaxy コレクション ---
echo ""
echo -e "${GREEN}[4/6] Ansible Galaxy コレクションをインストールします${NC}"
ansible-galaxy collection install -r requirements.yml

# --- proxmoxer Python パッケージ ---
echo ""
echo -e "${GREEN}[5/6] proxmoxer パッケージをインストールします${NC}"
pip3 install proxmoxer requests 2>/dev/null || pip install proxmoxer requests
echo -e "  ${GREEN}✓ proxmoxer インストール済み${NC}"

# --- hosts.yml リマインダー ---
echo ""
echo -e "${GREEN}[6/6] 設定確認${NC}"
echo ""
echo -e "${YELLOW}  以下を環境に合わせて編集してください:${NC}"
echo "    inventory/hosts.yml          — 各 VM の ansible_host と vm_id"
echo "    inventory/group_vars/all.yml — proxmox_host, proxmox_node, vm_bridge, vm_gateway 等"
echo ""
echo "  編集後、以下でクラスタを構築できます:"
echo -e "    ${GREEN}make deploy${NC}"
echo ""
echo "=================================================="
echo "  セットアップ完了"
echo "=================================================="
