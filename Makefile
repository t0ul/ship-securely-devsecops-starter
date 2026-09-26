# ==== config ====
APP_NAME=app
IMAGE=ship-securely/app:dev
PROFILE=ship
NAMESPACE=ship
K8S_DIR=infra/k8s
SBOM_FILE=artifacts/sbom.json

# ==== CI ====
ci: init build dockerlint sast secrets iac sbom sign verify sca

init:
	@mkdir -p artifacts .trivy-db

build:
	docker build -t $(IMAGE) app

dockerlint: init
	@echo "== Hadolint (Dockerfile) =="
	@docker run --rm \
	  -v $(PWD)/app/Dockerfile:/Dockerfile:ro \
	  hadolint/hadolint hadolint /Dockerfile \
	  > artifacts/hadolint.txt 2> artifacts/hadolint.stderr || true
	@# If no findings, write a friendly note so the file isn't empty
	@[ -s artifacts/hadolint.txt ] || echo "No Hadolint findings." > artifacts/hadolint.txt
	@echo "wrote artifacts/hadolint.txt"

sast:
	@echo "== Semgrep (SAST) =="
	docker run --rm -v $(PWD):/src returntocorp/semgrep \
	  semgrep --config p/owasp-top-ten --config /src/tools/semgrep \
	  --json  --json-output /src/artifacts/semgrep.json \
	  /src/app || true

secrets:
	@echo "== TruffleHog (secrets) =="
	docker run --rm -v $(PWD):/repo -w /repo \
	  ghcr.io/trufflesecurity/trufflehog:latest \
	  filesystem --json . > artifacts/trufflehog.json || true
	@echo "wrote artifacts/trufflehog.json"

iac: init
	@echo "== Checkov (IaC) =="
	docker run --rm -v $(PWD):/work -w /work \
	  bridgecrew/checkov \
	  -d /work/infra -o json > artifacts/checkov.json || true
	@echo "wrote artifacts/checkov.json"

sbom:
	@echo "== Syft (SBOM) =="
	docker run --rm -v $(PWD):/work anchore/syft:latest scan dir:/work/app -o json > $(SBOM_FILE)

sign:
	@echo "== (Optional) Cosign sign image (skips if key missing) =="
	@if [ -f cosign.key ]; then \
		cosign sign --key cosign.key $(IMAGE); \
	else \
		echo "cosign.key not found; skipping sign"; \
	fi

verify:
	@echo "== (Optional) Cosign verify (skips if pub key missing) =="
	@if [ -f cosign.pub ]; then \
		cosign verify --key cosign.pub $(IMAGE) > artifacts/cosign-verify.txt || true; \
	else \
		echo "cosign.pub not found; skipping verify"; \
	fi

sca:
	@echo "== Trivy (image scan) =="
	docker run --rm \
		-v $(PWD):/workspace \
		-v $(PWD)/.trivy-db:/root/.cache/trivy \
		-v /var/run/docker.sock:/var/run/docker.sock \
		aquasec/trivy:latest \
		image --ignore-unfixed --format json \
		-o /workspace/artifacts/trivy-image.json $(IMAGE)

# ==== CD (Minikube) ====
cd: mk-up build mk-image-load k8s-ns k8s-apply k8s-verify zap
	@echo "✅ Deployed $(APP_NAME) to Minikube ($(PROFILE)) in namespace $(NAMESPACE)"

mk-up:
	@if ! minikube status -p $(PROFILE) >/dev/null 2>&1; then \
	  echo "⛵ Starting Minikube ($(PROFILE))"; \
	  minikube start -p $(PROFILE) --cpus=2 --memory=4096; \
	else echo "⛵ Minikube ($(PROFILE)) is running"; fi

mk-down:
	- minikube stop -p $(PROFILE) || true

mk-delete:
	- minikube delete -p $(PROFILE) || true

mk-image-load:
	minikube -p $(PROFILE) image load $(IMAGE)

k8s-ns:
	- kubectl get ns $(NAMESPACE) >/dev/null 2>&1 || kubectl create ns $(NAMESPACE)

k8s-apply:
	@if [ -f "$(K8S_DIR)/kustomization.yaml" ]; then \
	  kubectl -n $(NAMESPACE) apply -k $(K8S_DIR); \
	else \
	  kubectl -n $(NAMESPACE) apply -f $(K8S_DIR); \
	fi
	-kubectl -n $(NAMESPACE) set image deploy/$(APP_NAME) $(APP_NAME)=$(IMAGE)

k8s-verify:
	kubectl -n $(NAMESPACE) rollout status deploy/$(APP_NAME)

k8s-port:
	@minikube -p $(PROFILE) service $(APP_NAME) -n $(NAMESPACE) --url

k8s-logs:
	kubectl -n $(NAMESPACE) logs -l app=$(APP_NAME) -f --tail=200

# ==== ZAP (via port-forward) ====
ZAP_MINS?=1
ZAP_TIMEOUT?=3

zap:
	@echo "== OWASP ZAP (baseline via port-forward) =="
	@mkdir -p artifacts/zap
	( kubectl -n $(NAMESPACE) port-forward deploy/$(APP_NAME) 8080:3000 >/dev/null 2>&1 & echo $$! > .pf.pid )
	@for i in $$(seq 1 20); do \
	  sleep 1; \
	  if curl -fsS http://localhost:8080/healthz >/dev/null; then echo "Port-forward is live"; break; fi; \
	  if ! kill -0 $$(cat .pf.pid) 2>/dev/null; then echo "Port-forward exited"; rm -f .pf.pid; exit 0; fi; \
	  if [ $$i -eq 20 ]; then echo "Timed out waiting"; kill $$(cat .pf.pid) 2>/dev/null || true; rm -f .pf.pid; exit 0; fi; \
	done
	@URL=http://host.docker.internal:8080; \
	echo "ZAP target: $$URL"; \
	docker run --rm -t --add-host=host.docker.internal:host-gateway \
	  -v $(PWD)/tools/zap:/zap/wrk -w /zap/wrk \
	  zaproxy/zap-stable:latest \
	  zap-baseline.py -t $$URL -m $(ZAP_MINS) -T $(ZAP_TIMEOUT) -s \
	  -r report.html -J report.json || true
	-@kill $$(cat .pf.pid) 2>/dev/null || true; rm -f .pf.pid
