# 実装ガイド

Proxmox + Ansible K8s クラスタ構築プロジェクトの詳細な実装解説。

---

## 目次

1. [全体アーキテクチャ](#1-全体アーキテクチャ)
2. [Phase 1: テンプレート作成](#2-phase-1-テンプレート作成)
3. [Phase 2: VM プロビジョニング](#3-phase-2-vm-プロビジョニング)
4. [Phase 3: OS 共通セットアップ](#4-phase-3-os-共通セットアップ)
5. [Phase 4: Control Plane 初期化](#5-phase-4-control-plane-初期化)
6. [Phase 5-6: Worker / Storage Join](#6-phase-5-6-worker--storage-join)
7. [Phase 7: Longhorn デプロイ](#7-phase-7-longhorn-デプロイ)
8. [ロール分離の設計方針](#8-ロール分離の設計方針)
9. [変数の階層構造](#9-変数の階層構造)
10. [トラブルシューティング](#10-トラブルシューティング)
11. [カスタマイズ例](#11-カスタマイズ例)

---

## 1. 全体アーキテクチャ

### 実行フロー

```
┌─────────────────────────────────────────────────────────────┐
│ Ansible 制御ノード                                          │
│                                                             │
│  site.yml                                                   │
│    │                                                        │
│    ├── 00: Proxmox API → テンプレートVM作成                  │
│    ├── 01: テンプレート → CP VM クローン                     │
│    ├── 02: テンプレート → Worker VM x2 クローン              │
│    ├── 03: テンプレート → Storage VM クローン                │
│    ├── 04: 全4ノード → OS共通設定 + containerd + kubeadm     │
│    ├── 05: CP → kubeadm init + Calico                       │
│    ├── 06: Worker x2 → kubeadm join (serial: 1)             │
│    ├── 07: Storage → kubeadm join + ラベル/taint             │
│    └── 08: CP → Longhorn デプロイ                            │
│                                                             │
└─────────────────────────────────────────────────────────────┘

┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│  k8s-cp01    │  │ k8s-worker01 │  │ k8s-worker02 │  │k8s-storage01 │
│  CP (init)   │  │ Worker (join)│  │ Worker (join)│  │Storage (join)│
│  4C/8G/50G   │  │  4C/8G/50G   │  │  4C/8G/50G   │  │ 2C/4G/100G   │
│  Calico      │  │  worker label│  │  worker label│  │ storage label│
│  kubeconfig  │  │              │  │              │  │ NoSchedule   │
│  Longhorn mgr│  │              │  │              │  │ Longhorn data│
└──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘
       │                │                │                │
       └────────────────┴────────────────┴────────────────┘
                    Proxmox VE (vmbr0)
```

### Ansible のホストグループ構造

```yaml
all
├── proxmox          # Proxmox ホスト (VM作成のみ)
│   └── pve01
└── k8s_cluster      # 全K8sノード (共通セットアップ対象)
    ├── control_plane
    │   └── k8s-cp01
    ├── workers
    │   ├── k8s-worker01
    │   └── k8s-worker02
    └── storage
        └── k8s-storage01
```

---

## 2. Phase 1: テンプレート作成

**Playbook**: `00_create_template.yml` → **Role**: `proxmox_template`

### 処理内容

1. Debian 12 cloud-image (qcow2) を Proxmox ホストの `/tmp/` にダウンロード
2. `qm create` で VM ID 9000 のシェルを作成
3. `qm set --scsi0 ... import-from=...` で cloud-image をディスクとしてインポート
4. cloud-init ドライブ (IDE2) を追加
5. ブート順序、シリアルコンソール、cloud-init デフォルト値を設定
6. `qm template` でテンプレート化

### なぜ shell モジュールを使うか

Proxmox の `community.general.proxmox_kvm` モジュールは VM の作成・起動・停止に対応しているが、**cloud-init テンプレートの一連のセットアップ**（importdisk、cloud-init ドライブ追加、テンプレート化）には対応していないため、`qm` コマンドを直接実行している。

### べき等性

`qm status {{ vm_template_id }}` でテンプレートの存在を事前チェックしており、既に存在する場合はスキップされる（`when: template_exists.rc != 0` ブロック）。

---

## 3. Phase 2: VM プロビジョニング

**Playbooks**: `01_create_cp_vm.yml`, `02_create_worker_vms.yml`, `03_create_storage_vm.yml`
**Roles**: `proxmox_vm_cp`, `proxmox_vm_worker`, `proxmox_vm_storage`

### 各ロールの共通処理フロー

```
テンプレートからフルクローン
  → VMスペック設定 (CPU/メモリ)
    → ディスクリサイズ (qm resize)
      → cloud-init ネットワーク設定 (静的IP)
        → VM起動
          → SSH到達確認 (wait_for port 22)
```

### VM作成で使用するモジュール

| 処理 | モジュール | 理由 |
|------|-----------|------|
| クローン | `community.general.proxmox_kvm` | API 経由で安全にクローン |
| スペック変更 | `community.general.proxmox_kvm` (update) | CPU/メモリ変更 |
| ディスクリサイズ | `ansible.builtin.command` (qm resize) | モジュール非対応 |
| cloud-init IP設定 | `ansible.builtin.command` (qm set --ipconfig0) | モジュール制限 |
| 起動 | `community.general.proxmox_kvm` (state: started) | API 経由 |

### IP アドレスの割り当て

各 VM の IP は `inventory/hosts.yml` の `ansible_host` に定義されており、cloud-init の `--ipconfig0` パラメータで静的に注入される。DHCP ではなく固定 IP を使用するのは、K8s クラスタのノード間通信で IP の不変性が必要なため。

---

## 4. Phase 3: OS 共通セットアップ

**Playbook**: `04_common_setup.yml` → **Roles**: `common`, `containerd`, `kubeadm`

### common ロール

K8s ノードの前提条件を設定:

```
swap無効化 (swapoff -a + fstab削除)
  → カーネルモジュール (overlay, br_netfilter)
    → sysctl (bridge-nf-call-iptables, ip_forward)
      → /etc/hosts 全ノード登録
        → 基本パッケージインストール
```

**swap 無効化が必要な理由**: kubelet はデフォルトで swap が有効だと起動を拒否する。K8s のメモリ管理はノードの実メモリに基づくため。

**カーネルモジュールが必要な理由**:
- `overlay`: containerd のストレージドライバが OverlayFS を使用
- `br_netfilter`: ブリッジ経由のトラフィックに iptables ルールを適用（Pod 間通信に必須）

### containerd ロール

```
Docker GPGキー追加 → Docker APTリポジトリ追加
  → containerd.io インストール
    → デフォルト設定生成
      → SystemdCgroup = true に変更 → restart handler
```

**SystemdCgroup を有効にする理由**: K8s 1.22+ では cgroup v2 + systemd が推奨。kubelet と containerd の cgroup ドライバを統一しないと、Pod 起動時に cgroup 関連エラーが発生する。

### kubeadm ロール

```
Kubernetes GPGキー追加 → K8s APTリポジトリ追加
  → kubeadm, kubelet, kubectl インストール
    → dpkg hold (バージョン固定)
      → kubelet サービス有効化
```

**バージョン固定 (hold) の理由**: `apt upgrade` で意図せず K8s コンポーネントがアップグレードされると、クラスタが壊れる可能性がある。アップグレードは `kubeadm upgrade` で計画的に行う。

---

## 5. Phase 4: Control Plane 初期化

**Playbook**: `05_init_control_plane.yml` → **Role**: `control_plane_init`

### 処理フロー

```
kubeadm init (pod-network-cidr, service-cidr, apiserver-advertise-address)
  → ~/.kube/config にadmin kubeconfig コピー
    → Calico マニフェストダウンロード＆適用
      → kubeadm token create --print-join-command
        → set_fact: kubeadm_join_command (cacheable)
          → ノード Ready 状態待機 (retry 30回, 10秒間隔)
```

### join コマンドの受け渡し

`control_plane_init` で取得した join コマンドは `set_fact` + `cacheable: true` で Ansible のファクトキャッシュに保存される。後続の `worker_join` と `storage_join` ロールは以下のように参照する:

```yaml
{{ hostvars[groups['control_plane'][0]].kubeadm_join_command }}
```

これにより、CP の初期化と Worker/Storage の join が異なる play であっても、join 情報が引き継がれる。

### Calico CNI を選定した理由

| 項目 | Calico | Flannel |
|------|--------|---------|
| NetworkPolicy | ○ 対応 | × 非対応 |
| パフォーマンス | eBPF モード対応 | VXLAN のみ |
| 学習コスト | やや高い | 低い |

本プロジェクトでは NetworkPolicy によるセキュリティ制御を見据えて Calico を採用。

---

## 6. Phase 5-6: Worker / Storage Join

### Worker Join (`worker_join` ロール)

```
kubelet.conf 存在チェック (べき等性)
  → kubeadm join 実行
    → kubectl label: node-role.kubernetes.io/worker=""
      → ノード Ready 状態待機
```

**`serial: 1` の理由**: Worker ノードを1台ずつ join させることで、クラスタの etcd への同時書き込みを避け、安定性を確保する。

### Storage Join (`storage_join` ロール)

Worker とは異なり、Storage 固有の追加処理がある:

```
open-iscsi, nfs-common インストール (Longhorn前提)
  → iscsid サービス有効化
    → kubeadm join 実行
      → kubectl label: node-role.kubernetes.io/storage=""
        → kubectl label: node.longhorn.io/create-default-disk=true
          → kubectl taint: node-role.kubernetes.io/storage=:NoSchedule
            → ノード Ready 状態待機
```

### Storage ノードの taint 戦略

```
NoSchedule taint
  → 通常の Pod はスケジュールされない
  → Longhorn コンポーネントのみ toleration で配置される
  → Storage ノードのリソースを Longhorn に専有させる
```

---

## 7. Phase 7: Longhorn デプロイ

**Playbook**: `08_deploy_longhorn.yml` → **Role**: `longhorn`

### 処理フロー

```
全ノードに open-iscsi, nfs-common インストール (delegate_to + loop)
  → longhorn-system namespace 作成
    → Longhorn マニフェストダウンロード＆適用
      → taint-toleration 設定パッチ (storage ノード NoSchedule 対応)
        → デフォルト StorageClass 設定
          → longhorn-manager DaemonSet rollout 待機 (300s)
```

### なぜ全ノードに iSCSI が必要か

Longhorn はレプリカをクラスタ内の複数ノードに分散配置する。Volume を使う Pod がスケジュールされたノードで iSCSI initiator が必要になるため、Worker ノードにも `open-iscsi` が必要。

### Toleration パッチ

Storage ノードに `NoSchedule` taint を付与しているため、Longhorn コンポーネントも toleration がないとスケジュールされない。`settings.longhorn.io/taint-toleration` をパッチして、Longhorn が storage ノードのtaint を tolerate するよう設定。

```yaml
# retry 10回, 15秒間隔で待機
# → Longhorn Settings CRD が作成されるまで待つ必要があるため
```

---

## 8. ロール分離の設計方針

### VM 作成ロールの分離 (3ロール)

| ロール | 分離理由 |
|--------|----------|
| `proxmox_vm_cp` | CP 固有のスペック (4C/8G)。1台のみ作成。将来 HA 化で拡張時に独立変更可能 |
| `proxmox_vm_worker` | 複数台を `hosts: workers` でループ処理。台数追加が容易 |
| `proxmox_vm_storage` | 大容量ディスク (100G)。将来の追加ディスク対応で拡張が必要になる可能性 |

### K8s Join ロールの分離 (3ロール)

| ロール | 分離理由 |
|--------|----------|
| `control_plane_init` | `kubeadm init` + CNI + token 生成と、他の join とは処理が完全に異なる |
| `worker_join` | join + worker ラベルのみのシンプルな処理 |
| `storage_join` | join + ラベル + taint + iSCSI/NFS と、storage 固有の処理が多い |

### 共通ロールの統合 (3ロール)

`common`, `containerd`, `kubeadm` は全ノード共通のため統合。`04_common_setup.yml` で一括適用:

```yaml
roles:
  - common       # OS設定
  - containerd   # CRI
  - kubeadm      # K8sツール
```

---

## 9. 変数の階層構造

Ansible の変数優先順位に従い、以下の階層で変数を管理:

```
inventory/group_vars/all.yml          # 全ホスト共通 (Proxmox接続情報等)
  ↓ 上書き
inventory/group_vars/k8s_cluster.yml  # K8s全ノード共通 (バージョン等)
  ↓ 上書き
inventory/group_vars/control_plane.yml  # CPグループ固有
inventory/group_vars/workers.yml        # Workerグループ固有
inventory/group_vars/storage.yml        # Storageグループ固有
  ↓ 上書き
inventory/hosts.yml (host_vars)         # ホスト固有 (ansible_host, vm_id)
  ↓ 上書き
roles/*/defaults/main.yml              # ロールデフォルト (最低優先)
```

**例**: `vm_cores` は `roles/proxmox_vm_cp/defaults/main.yml` で `4` だが、`inventory/group_vars/storage.yml` で `2` に上書きされる。

---

## 10. トラブルシューティング

### テンプレート作成失敗

```bash
# テンプレートVMの状態確認
ssh root@proxmox "qm status 9000"

# テンプレートの設定確認
ssh root@proxmox "qm config 9000"

# テンプレートを削除して再作成
ssh root@proxmox "qm destroy 9000"
ansible-playbook playbooks/00_create_template.yml
```

### VM がクローンされない

```bash
# Proxmox ストレージの空き容量確認
ssh root@proxmox "pvesm status"

# 特定 VM の存在確認
ssh root@proxmox "qm list"
```

### kubeadm init 失敗

```bash
# CP ノードでログ確認
ssh k8s@192.168.1.101 "sudo journalctl -xeu kubelet"

# リセットして再実行
ssh k8s@192.168.1.101 "sudo kubeadm reset -f"
ansible-playbook playbooks/05_init_control_plane.yml
```

### Worker が join できない

```bash
# token の有効期限確認 (デフォルト24時間)
ssh k8s@192.168.1.101 "sudo kubeadm token list"

# token 再生成 → 再 join
ansible-playbook playbooks/05_init_control_plane.yml  # token再生成
ansible-playbook playbooks/06_join_workers.yml
```

### Longhorn が起動しない

```bash
# Pod の状態確認
kubectl -n longhorn-system get pods

# DaemonSet の状態確認
kubectl -n longhorn-system describe daemonset longhorn-manager

# iSCSI が有効か確認 (全ノードで)
ssh k8s@192.168.1.101 "systemctl status iscsid"
```

---

## 11. カスタマイズ例

### Worker ノードを3台に増やす

1. `inventory/hosts.yml` に Worker を追加:

```yaml
workers:
  hosts:
    k8s-worker01:
      ansible_host: 192.168.1.102
      vm_id: 202
    k8s-worker02:
      ansible_host: 192.168.1.103
      vm_id: 203
    k8s-worker03:            # 追加
      ansible_host: 192.168.1.105
      vm_id: 205
```

2. 実行:

```bash
ansible-playbook playbooks/02_create_worker_vms.yml
ansible-playbook playbooks/04_common_setup.yml --limit k8s-worker03
ansible-playbook playbooks/06_join_workers.yml --limit k8s-worker03
```

### VM スペックの変更

`inventory/group_vars/workers.yml` を編集:

```yaml
vm_cores: 8      # 4 → 8
vm_memory: 16384  # 8GB → 16GB
vm_disk_size: "100G"
```

### CNI を Flannel に変更

`inventory/group_vars/k8s_cluster.yml`:

```yaml
# Calico → Flannel
calico_manifest_url: "https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml"
```

`roles/control_plane_init/tasks/main.yml` の Calico 関連タスクの URL 変数を上記に合わせる。

### Proxmox クラスタ (複数ノード) 対応

`inventory/hosts.yml`:

```yaml
proxmox:
  hosts:
    pve01:
      ansible_host: 192.168.1.10
    pve02:
      ansible_host: 192.168.1.11
```

各 VM の `proxmox_node` を個別に指定して、VM を異なる Proxmox ノードに分散配置可能。
