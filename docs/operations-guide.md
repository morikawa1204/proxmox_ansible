# 運用ガイド

Proxmox + Ansible K8s クラスタの初回セットアップから日常運用まで。

---

## 目次

1. [前提条件](#1-前提条件)
2. [初回セットアップ](#2-初回セットアップ)
3. [ワンコマンドデプロイ](#3-ワンコマンドデプロイ)
4. [個別フェーズ実行](#4-個別フェーズ実行)
5. [事前バリデーション (preflight)](#5-事前バリデーション-preflight)
6. [Ansible Vault の管理](#6-ansible-vault-の管理)
7. [設定変数リファレンス](#7-設定変数リファレンス)
8. [クラスタ構築後の確認](#8-クラスタ構築後の確認)
9. [よくある失敗と対処法](#9-よくある失敗と対処法)

---

## 1. 前提条件

### 制御ノード (Ansible を実行する PC / サーバー)

| ソフトウェア | バージョン | インストール確認 |
|---|---|---|
| Ansible | 2.15 以上 | `ansible --version` |
| Python | 3.9 以上 | `python3 --version` |
| make | 任意 | `make --version` |

```bash
# Ansible のインストール (pip)
pip3 install ansible
```

### Proxmox VE ホスト

- Proxmox VE 8.x がセットアップ済みで、root SSH アクセスが可能
- `local-lvm` ストレージに VM が作成できる空き容量 (最低 350 GB)
- インターネット接続 (Debian cloud image のダウンロード)

### ネットワーク

- 制御ノードから Proxmox ホストへ **TCP 8006 (API)** および **TCP 22 (SSH)** が到達可能
- VM 用の固定 IP 帯 (`192.168.1.101`〜`192.168.1.104`) が確保済み

---

## 2. 初回セットアップ

### 2-1. リポジトリの配置

```bash
cd /path/to/proxmox_ansible
```

### 2-2. setup.sh の実行

```bash
bash setup.sh
```

ウィザードが以下を対話的に実行します:

| ステップ | 内容 |
|---|---|
| 1 | Ansible バージョン確認 |
| 2 | `vault.yml` を生成し、Proxmox パスワード・VM パスワード・SSH 公開鍵を設定 |
| 3 | `ansible-vault encrypt` で vault.yml を暗号化、`.vault_pass` を生成 |
| 4 | SSH 秘密鍵のパスを `ansible.cfg` に反映 |
| 5 | Ansible Galaxy コレクションをインストール |

> **重要**: `.vault_pass` は秘密情報です。`.gitignore` で git 管理外になっています。紛失した場合は vault.yml を再作成してください。

### 2-3. インベントリの編集

環境に合わせて以下2ファイルを編集します:

#### `inventory/hosts.yml`

```yaml
control_plane:
  hosts:
    k8s-cp01:
      ansible_host: 192.168.1.101  # ← 実際のIP
      vm_id: 201                    # ← 既存VMと衝突しない値

workers:
  hosts:
    k8s-worker01:
      ansible_host: 192.168.1.102
      vm_id: 202
    k8s-worker02:
      ansible_host: 192.168.1.103
      vm_id: 203

storage:
  hosts:
    k8s-storage01:
      ansible_host: 192.168.1.104
      vm_id: 204
```

#### `inventory/group_vars/all.yml` (主要項目のみ)

```yaml
proxmox_host: "192.168.1.10"   # Proxmox ホストの IP
proxmox_node: "pve01"           # Proxmox ノード名 (pvesh nodes で確認)
vm_bridge: "vmbr0"              # Proxmox のブリッジ名
vm_gateway: "192.168.1.1"       # VM のデフォルトゲートウェイ
vm_nameserver: "192.168.1.1"    # DNS サーバー
```

---

## 3. ワンコマンドデプロイ

セットアップ完了後、以下の1コマンドでクラスタ全体が構築されます:

```bash
make deploy
```

内部フロー:

```
make deploy
  ├── make install   → ansible-galaxy collection install -r requirements.yml
  ├── make preflight → playbooks/preflight.yml (事前バリデーション)
  └── ansible-playbook playbooks/site.yml
        ├── Phase 0: Preflight (二重確認)
        ├── Phase 1: Debian 12 テンプレート作成 (Proxmox)
        ├── Phase 2: VM 作成 (CP + Worker x2 + Storage)
        ├── Phase 3: OS 共通設定 (swap 無効化 / containerd / kubeadm)
        ├── Phase 4: Control Plane 初期化 (kubeadm init + Calico)
        ├── Phase 5: Worker Join (serial: 1 で1台ずつ)
        ├── Phase 6: Storage Join (ラベル / taint / iSCSI)
        ├── Phase 7: Longhorn デプロイ
        └── Phase 8: Istio デプロイ (istiod + ingressgateway)
```

所要時間の目安:

| フェーズ | 時間 |
|---|---|
| Phase 1-2 (VM 作成) | 約 15-20 分 |
| Phase 3 (OS セットアップ) | 約 10 分 |
| Phase 4-6 (K8s 構築) | 約 15 分 |
| Phase 7-8 (Longhorn + Istio) | 約 15 分 |
| **合計** | **約 55-60 分** |

---

## 4. 個別フェーズ実行

クラスタが既に存在する場合や、特定フェーズだけ再実行したい場合:

```bash
# フェーズ番号を指定
make phase N=05   # Control Plane 初期化のみ
make phase N=08   # Longhorn のみ
make phase N=09   # Istio のみ

# 直接 playbook を指定する場合
ansible-playbook playbooks/06_join_workers.yml

# 特定ホストのみ (common セットアップを再適用など)
ansible-playbook playbooks/04_common_setup.yml --limit k8s-worker01
```

| N | Playbook | 内容 |
|---|---|---|
| 00 | `00_create_template.yml` | Debian 12 テンプレート VM 作成 |
| 01 | `01_create_cp_vm.yml` | Control Plane VM 作成 |
| 02 | `02_create_worker_vms.yml` | Worker VM x2 作成 |
| 03 | `03_create_storage_vm.yml` | Storage VM 作成 |
| 04 | `04_common_setup.yml` | OS 共通設定 + containerd + kubeadm |
| 05 | `05_init_control_plane.yml` | kubeadm init + Calico + join token 生成 |
| 06 | `06_join_workers.yml` | Worker x2 を join |
| 07 | `07_join_storage.yml` | Storage を join + ラベル/taint |
| 08 | `08_deploy_longhorn.yml` | Longhorn デプロイ |
| 09 | `09_deploy_istio.yml` | Istio デプロイ |

---

## 5. 事前バリデーション (preflight)

実際のデプロイ前に環境が整っているか確認できます:

```bash
make preflight
```

チェック内容:

| チェック | 確認内容 |
|---|---|
| Ansible バージョン | 2.15 以上であること |
| vault.yml | ファイルが存在すること |
| .vault_pass | ファイルが存在すること |
| SSH 秘密鍵 | `ansible.cfg` に指定したパスのファイルが存在すること |
| Galaxy コレクション | `community.general` / `kubernetes.core` / `ansible.posix` がインストール済み |
| Proxmox API | `https://<proxmox_host>:8006/api2/json/version` に HTTP 200 で応答すること |

---

## 6. Ansible Vault の管理

### vault.yml の内容確認・編集

```bash
# 復号して確認
ansible-vault view inventory/group_vars/vault.yml

# 復号して編集
ansible-vault edit inventory/group_vars/vault.yml
```

### パスワード変更

```bash
# vault のパスワードを変更
ansible-vault rekey inventory/group_vars/vault.yml

# .vault_pass も更新
echo "新しいパスワード" > .vault_pass
chmod 600 .vault_pass
```

### vault.yml を紛失・再作成する場合

```bash
cp inventory/group_vars/vault.yml.example inventory/group_vars/vault.yml
# 値を編集してから暗号化
ansible-vault encrypt inventory/group_vars/vault.yml
# 新しい .vault_pass を作成
echo "パスワード" > .vault_pass && chmod 600 .vault_pass
```

---

## 7. 設定変数リファレンス

### `inventory/group_vars/all.yml`

| 変数 | デフォルト | 説明 |
|---|---|---|
| `proxmox_host` | `192.168.1.10` | Proxmox ホストの IP |
| `proxmox_node` | `pve01` | Proxmox ノード名 |
| `vm_template_id` | `9000` | テンプレート VM の ID |
| `vm_storage` | `local-lvm` | VM ディスクの配置先ストレージ |
| `vm_bridge` | `vmbr0` | ネットワークブリッジ |
| `vm_gateway` | `192.168.1.1` | VM のデフォルトゲートウェイ |
| `vm_nameserver` | `192.168.1.1` | DNS |

### `inventory/group_vars/k8s_cluster.yml`

| 変数 | デフォルト | 説明 |
|---|---|---|
| `k8s_version` | `1.31` | Kubernetes バージョン |
| `pod_network_cidr` | `10.244.0.0/16` | Pod ネットワーク CIDR |
| `service_cidr` | `10.96.0.0/12` | Service CIDR |
| `calico_version` | `v3.28.0` | Calico CNI バージョン |
| `longhorn_version` | `v1.7.0` | Longhorn バージョン |
| `istio_version` | `1.24.3` | Istio バージョン |
| `istio_profile` | `default` | Istio インストールプロファイル |

### `inventory/group_vars/vault.yml` (暗号化済み・編集は `ansible-vault edit`)

| 変数 | 説明 |
|---|---|
| `vault_proxmox_password` | Proxmox root パスワード |
| `vault_cloud_init_password` | VM ユーザー (k8s) パスワード |
| `vault_ssh_public_key` | VM に登録する SSH 公開鍵 |

---

## 8. クラスタ構築後の確認

```bash
# Control Plane に SSH
ssh k8s@192.168.1.101

# 全ノードが Ready
kubectl get nodes

# ノードラベル確認
kubectl get nodes --show-labels

# Storage taint 確認
kubectl describe node k8s-storage01 | grep Taint

# Longhorn StorageClass 確認
kubectl get sc

# Longhorn Pod 確認
kubectl -n longhorn-system get pods

# Istio コンポーネント確認
kubectl -n istio-system get pods

# istiod バージョン確認
kubectl -n istio-system get deployment istiod \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# Ingress Gateway サービス確認
kubectl -n istio-system get svc istio-ingressgateway

# テスト PVC (Longhorn 動作確認)
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF

kubectl get pvc test-pvc
# STATUS: Bound になれば正常
kubectl delete pvc test-pvc
```

---

## 9. よくある失敗と対処法

### `preflight` で Proxmox API に到達できない

```
原因: proxmox_host の IP が間違っている、またはファイアウォールで 8006 がブロックされている

確認:
  curl -k https://<proxmox_host>:8006/api2/json/version

対処:
  inventory/group_vars/all.yml の proxmox_host を修正
```

### Phase 1 でテンプレート作成が失敗する

```
原因: vm_template_id (デフォルト 9000) が既存 VM と衝突

確認:
  ssh root@<proxmox_host> "qm list"

対処:
  inventory/group_vars/all.yml の vm_template_id を空き番号に変更してから再実行
  ansible-playbook playbooks/00_create_template.yml
```

### Phase 2 で VM クローンがタイムアウトする

```
原因: Proxmox ストレージの空き容量不足、または NFS ストレージが遅い

確認:
  ssh root@<proxmox_host> "pvesm status"

対処:
  ストレージを確保してから再実行 (べき等なので途中から再開できる)
  ansible-playbook playbooks/01_create_cp_vm.yml
```

### Phase 3 以降で SSH 接続ができない

```
原因: ansible.cfg の private_key_file が vault.yml の vault_ssh_public_key と対になっていない

確認:
  ssh -i ~/.ssh/id_ed25519 k8s@192.168.1.101

対処:
  setup.sh を再実行するか、ansible.cfg の private_key_file を正しい秘密鍵パスに修正
```

### kubeadm join トークンが期限切れ (Phase 5-6 を分割実行した場合)

```
原因: join トークンはデフォルト 24 時間で失効

対処:
  # CP でトークンを再生成
  ansible-playbook playbooks/05_init_control_plane.yml

  # その後 join を再実行
  ansible-playbook playbooks/06_join_workers.yml
  ansible-playbook playbooks/07_join_storage.yml
```

### Longhorn が storage ノードにスケジュールされない

```
原因: storage ノードの NoSchedule taint に対する Longhorn の toleration 設定が
      Longhorn CRD の準備完了前に適用されるとリトライが必要な場合がある

確認:
  kubectl -n longhorn-system get pods
  kubectl -n longhorn-system describe daemonset longhorn-manager

対処:
  ansible-playbook playbooks/08_deploy_longhorn.yml  # べき等なので再実行可能
```

### Istio インストールが失敗する

```
原因: Kubernetes バージョンと Istio バージョンの非互換

確認:
  https://istio.io/latest/docs/releases/supported-releases/

対処:
  inventory/group_vars/k8s_cluster.yml の istio_version を対応バージョンに変更
  ansible-playbook playbooks/09_deploy_istio.yml
```

### `make` が使えない (Windows 環境)

```
対処: Makefile の代わりに直接コマンドを実行

  # make deploy の等価コマンド
  ansible-galaxy collection install -r requirements.yml
  ansible-playbook playbooks/preflight.yml
  ansible-playbook playbooks/site.yml
```
