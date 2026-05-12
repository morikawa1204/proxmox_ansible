.DEFAULT_GOAL := help

# ================================================================
# Proxmox Ansible K8s Cluster — タスクランナー
# 使用方法: make <target>
# ================================================================

.PHONY: help setup install preflight deploy phase clean

help: ## このヘルプを表示する
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  例:"
	@echo "    make deploy              # ワンコマンドで全フェーズ実行"
	@echo "    make phase N=5           # Phase 5 (Control Plane 初期化) のみ実行"
	@echo "    make phase N=8           # Phase 8 (Istio) のみ実行"

setup: ## 初回セットアップウィザード (vault.yml 生成 + Galaxy コレクション)
	@bash setup.sh

install: ## Ansible Galaxy コレクションをインストール
	ansible-galaxy collection install -r requirements.yml

preflight: ## 事前バリデーションのみ実行 (Proxmox 到達確認・vault 確認等)
	ansible-playbook playbooks/preflight.yml

deploy: install preflight ## ワンコマンド: install → preflight → 全フェーズ実行
	ansible-playbook playbooks/site.yml

# 個別フェーズ実行: make phase N=<番号>
# 00=template, 01=cp_vm, 02=worker_vms, 03=storage_vm, 04=common,
# 05=init_cp, 06=join_workers, 07=join_storage, 08=longhorn, 09=istio
PHASE_MAP_00 = playbooks/00_create_template.yml
PHASE_MAP_01 = playbooks/01_create_cp_vm.yml
PHASE_MAP_02 = playbooks/02_create_worker_vms.yml
PHASE_MAP_03 = playbooks/03_create_storage_vm.yml
PHASE_MAP_04 = playbooks/04_common_setup.yml
PHASE_MAP_05 = playbooks/05_init_control_plane.yml
PHASE_MAP_06 = playbooks/06_join_workers.yml
PHASE_MAP_07 = playbooks/07_join_storage.yml
PHASE_MAP_08 = playbooks/08_deploy_longhorn.yml
PHASE_MAP_09 = playbooks/09_deploy_istio.yml

phase: ## 特定フェーズのみ実行 (例: make phase N=05)
ifndef N
	$(error N を指定してください。例: make phase N=05)
endif
	ansible-playbook $(PHASE_MAP_$(N))

clean: ## Ansible のキャッシュ・一時ファイルを削除
	@find . -name "*.retry" -delete
	@rm -rf .ansible/ fact_cache/
	@echo "クリーンアップ完了"
