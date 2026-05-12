# Proxmox + Ansible Kubernetes Cluster

Proxmox VE 上に Debian 12 ベースの VM 4台を自動構築し、kubeadm で Kubernetes クラスタを構成する Ansible プロジェクト。

## クラスタ構成

| ロール | ホスト名 | CPU | メモリ | ディスク | IP (デフォルト) |
|--------|----------|-----|--------|----------|-----------------|
| Control Plane | k8s-cp01 | 4 | 8GB | 50GB | 192.168.1.101 |
| Worker Node 1 | k8s-worker01 | 4 | 8GB | 50GB | 192.168.1.102 |
| Worker Node 2 | k8s-worker02 | 4 | 8GB | 50GB | 192.168.1.103 |
| Storage | k8s-storage01 | 2 | 4GB | 100GB | 192.168.1.104 |

## 技術スタック

| コンポーネント | 選定 |
|----------------|------|
| OS | Debian 12 (cloud-init) |
| Kubernetes | kubeadm v1.31 |
| CRI | containerd 1.7.x |
| CNI | Calico v3.28.0 |
| サービスメッシュ | Istio v1.24.3 |
| ストレージ | Longhorn v1.7.0 |
| IaC | Ansible + community.general |

## 前提条件

- Proxmox VE 8.x がセットアップ済み
- Ansible 2.15+ がインストール済みの制御ノード
- Proxmox API にアクセス可能なネットワーク環境
- VM 用の固定 IP アドレス帯を確保済み

## クイックスタート

```bash
# 1. 初回セットアップ (vault 生成 + SSH鍵設定 + Galaxy インストール)
bash setup.sh

# 2. 環境に合わせて設定を編集
vi inventory/group_vars/all.yml   # proxmox_host / vm_bridge / vm_gateway 等
vi inventory/hosts.yml            # 各 VM の IPアドレスと vm_id

# 3. ワンコマンドでクラスタ構築
make deploy
```

> **Windows 環境で make が使えない場合:**
> ```bash
> ansible-galaxy collection install -r requirements.yml
> ansible-playbook playbooks/preflight.yml
> ansible-playbook playbooks/site.yml
> ```

詳細な手順は [docs/operations-guide.md](docs/operations-guide.md) を参照してください。

## 設定変更 (実行前に必須)

### inventory/group_vars/all.yml

| 変数 | 説明 | 例 |
|------|------|-----|
| `proxmox_host` | Proxmox サーバーの IP | `192.168.1.10` |
| `proxmox_node` | Proxmox ノード名 | `pve01` |
| `vm_bridge` | Proxmox のブリッジ名 | `vmbr0` |
| `vm_gateway` | VM 用ゲートウェイ | `192.168.1.1` |
| `vm_nameserver` | DNS サーバー | `192.168.1.1` |

パスワード・ SSH 公開鍵は `bash setup.sh` で自動的に `inventory/group_vars/vault.yml` (暗号化済み) に設定されます。直接編集する場合は `ansible-vault edit inventory/group_vars/vault.yml` を使用してください。

### inventory/hosts.yml

各 VM の `ansible_host` と `vm_id` を実環境に合わせて変更:

```yaml
control_plane:
  hosts:
    k8s-cp01:
      ansible_host: 192.168.1.101  # ← 変更
      vm_id: 201                    # ← 変更
```

## ディレクトリ構成

```
proxmox/
├── ansible.cfg              # Ansible 基本設定
├── requirements.yml          # Ansible Galaxy 依存コレクション
├── inventory/
│   ├── hosts.yml             # ホスト定義 (Proxmox + VM 4台)
│   └── group_vars/
│       ├── all.yml           # Proxmox接続情報, cloud-init設定
│       ├── k8s_cluster.yml   # K8sバージョン, CNI, Longhorn設定
│       ├── control_plane.yml # CP VMスペック
│       ├── workers.yml       # Worker VMスペック
│       └── storage.yml       # Storage VMスペック
├── playbooks/
│   ├── site.yml              # 統合Playbook (全フェーズ順次実行)
│   ├── preflight.yml         # 事前バリデーション
│   ├── 00_create_template.yml
│   ├── 01_create_cp_vm.yml
│   ├── 02_create_worker_vms.yml
│   ├── 03_create_storage_vm.yml
│   ├── 04_common_setup.yml
│   ├── 05_init_control_plane.yml
│   ├── 06_join_workers.yml
│   ├── 07_join_storage.yml
│   ├── 08_deploy_longhorn.yml
│   └── 09_deploy_istio.yml
├── roles/                    # 12 ロール (下記参照)
└── templates/
    └── cloud-init-user-data.yml.j2
```

## ロール一覧

| ロール | 対象 | 内容 |
|--------|------|------|
| `proxmox_template` | Proxmox ホスト | Debian 12 cloud-image をDLし、cloud-init テンプレート VM を作成 |
| `proxmox_vm_cp` | Control Plane | テンプレートからクローン (4C/8G/50G)、静的IP設定、起動 |
| `proxmox_vm_worker` | Worker | テンプレートからクローン (4C/8G/50G)、静的IP設定、起動 |
| `proxmox_vm_storage` | Storage | テンプレートからクローン (2C/4G/100G)、静的IP設定、起動 |
| `common` | 全ノード | hostname設定、swap無効化、カーネルモジュール、sysctl |
| `containerd` | 全ノード | containerd インストール、SystemdCgroup 有効化 |
| `kubeadm` | 全ノード | kubeadm/kubelet/kubectl インストール、バージョン固定 |
| `control_plane_init` | CP のみ | `kubeadm init`、kubeconfig配布、Calico CNI デプロイ、join token 生成 |
| `worker_join` | Worker のみ | `kubeadm join` 実行、worker ラベル付与 |
| `storage_join` | Storage のみ | `kubeadm join`、storage ラベル/taint 付与、iSCSI/NFS インストール |
| `longhorn` | CP から実行 | 全ノードに前提パッケージ、Longhorn デプロイ、デフォルト StorageClass 設定 |
| `istio` | CP から実行 | istioctl ダウンロード、Istio インストール (istiod + ingressgateway)、起動確認 |

## Playbook 個別実行

一括実行 (`site.yml`) の代わりに、各フェーズを個別に実行可能:

```bash
# テンプレート作成のみ
ansible-playbook playbooks/00_create_template.yml

# CP VM だけ作成
ansible-playbook playbooks/01_create_cp_vm.yml

# K8s 初期化だけ実行 (VM が既に起動済みの場合)
ansible-playbook playbooks/05_init_control_plane.yml

# Istio だけデプロイ (クラスタ構築済みの場合)
ansible-playbook playbooks/09_deploy_istio.yml
```

## 検証コマンド

クラスタ構築後に以下で確認:

```bash
# 全ノードが Ready であること
kubectl get nodes

# ロールラベルの確認
kubectl get nodes --show-labels

# Storage ノードの taint 確認
kubectl describe node k8s-storage01 | grep Taint

# Longhorn StorageClass が存在すること
kubectl get sc

# Istio コンポーネントが Ready であること
kubectl -n istio-system get pods

# istiod のバージョン確認
kubectl -n istio-system get deployment istiod -o jsonpath='{.spec.template.spec.containers[0].image}'

# Ingress Gateway の External IP (LoadBalancer 未設定の場合は Pending で正常)
kubectl -n istio-system get svc istio-ingressgateway

# テスト PVC 作成
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

# Bound 確認後に削除
kubectl get pvc test-pvc
kubectl delete pvc test-pvc
```

## 注意事項

- 秘密情報 (Proxmoxパスワード・VMパスワード・SSH公開鍵) は `inventory/group_vars/vault.yml` に暗号化して管理される。`bash setup.sh` が自動生成する
- `.vault_pass` は `.gitignore` により git 管理外。絶対に commit しないこと
- Worker ノードの join は `serial: 1` で1台ずつ順次実行される（クラスタ安定性のため）
- Storage ノードには `NoSchedule` taint が付与され、Longhorn 以外の Pod はスケジュールされない
- VM テンプレートの ID はデフォルト `9000`。既存 VM ID と衝突する場合は `all.yml` の `vm_template_id` を変更
