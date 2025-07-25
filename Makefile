# SPDX-FileCopyrightText: 2024 SAP SE or an SAP affiliate company and Gardener contributors
#
# SPDX-License-Identifier: Apache-2.0

ENSURE_GARDENER_MOD         := $(shell go get github.com/gardener/gardener@$$(go list -m -f "{{.Version}}" github.com/gardener/gardener))
GARDENER_HACK_DIR           := $(shell go list -m -f "{{.Dir}}" github.com/gardener/gardener)/hack
EXTENSION_PREFIX            := gardener-extension
NAME                        := shoot-dns-service
ADMISSION_NAME              := admission-shoot-dns-service
REGISTRY                    := europe-docker.pkg.dev/gardener-project/public/gardener
IMAGE_PREFIX                := $(REGISTRY)/extensions
REPO_ROOT                   := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))
HACK_DIR                    := $(REPO_ROOT)/hack
VERSION                     := $(shell cat "$(REPO_ROOT)/VERSION")
EFFECTIVE_VERSION           := $(VERSION)-$(shell git rev-parse HEAD)
LD_FLAGS                    := "-w $(shell bash $(GARDENER_HACK_DIR)/get-build-ld-flags.sh k8s.io/component-base $(REPO_ROOT)/VERSION $(EXTENSION_PREFIX))"
LEADER_ELECTION             := false
IGNORE_OPERATION_ANNOTATION := true

WEBHOOK_CONFIG_PORT	:= 8443
WEBHOOK_CONFIG_MODE	:= url
WEBHOOK_CONFIG_URL	:= host.docker.internal:$(WEBHOOK_CONFIG_PORT)
EXTENSION_NAMESPACE	:=
WEBHOOK_PARAM := --webhook-config-url=$(WEBHOOK_CONFIG_URL)
ifeq ($(WEBHOOK_CONFIG_MODE), service)
  WEBHOOK_PARAM := --webhook-config-namespace=$(EXTENSION_NAMESPACE)
endif

ifneq ($(strip $(shell git status --porcelain 2>/dev/null)),)
	EFFECTIVE_VERSION := $(EFFECTIVE_VERSION)-dirty
endif

#########################################
# Tools                                 #
#########################################

TOOLS_DIR := hack/tools
include $(GARDENER_HACK_DIR)/tools.mk

#########################################
# Rules for local development scenarios #
#########################################

.PHONY: start
start:
	@LEADER_ELECTION_NAMESPACE=garden go run \
		-ldflags $(LD_FLAGS) \
		./cmd/$(EXTENSION_PREFIX)-$(NAME) \
		--ignore-operation-annotation=$(IGNORE_OPERATION_ANNOTATION) \
		--leader-election=$(LEADER_ELECTION) \
		--garden-id=garden \
		--seed-id=seed \
		--gardener-version="v1.85.0"

.PHONY: start-admission
start-admission:
	@LEADER_ELECTION_NAMESPACE=garden go run \
		-ldflags $(LD_FLAGS) \
		./cmd/$(EXTENSION_PREFIX)-$(ADMISSION_NAME) \
		--webhook-config-server-host=0.0.0.0 \
		--webhook-config-server-port=$(WEBHOOK_CONFIG_PORT) \
		--webhook-config-mode=$(WEBHOOK_CONFIG_MODE) \
        $(WEBHOOK_PARAM)

#################################################################
# Rules related to binary build, Docker image build and release #
#################################################################

.PHONY: install
install:
	@LD_FLAGS=$(LD_FLAGS) EFFECTIVE_VERSION=$(EFFECTIVE_VERSION) \
	bash $(GARDENER_HACK_DIR)/install.sh ./...

.PHONY: docker-login
docker-login:
	@gcloud auth activate-service-account --key-file .kube-secrets/gcr/gcr-readwrite.json

.PHONY: docker-images
docker-images:
	@docker build --build-arg EFFECTIVE_VERSION=$(EFFECTIVE_VERSION) -t $(IMAGE_PREFIX)/$(NAME):$(VERSION) -t $(IMAGE_PREFIX)/$(NAME):latest -f Dockerfile -m 6g --target $(EXTENSION_PREFIX)-$(NAME) .
	@docker build --build-arg EFFECTIVE_VERSION=$(EFFECTIVE_VERSION) -t $(IMAGE_PREFIX)/$(ADMISSION_NAME):$(VERSION) -t $(IMAGE_PREFIX)/$(ADMISSION_NAME):latest -f Dockerfile -m 6g --target $(EXTENSION_PREFIX)-$(ADMISSION_NAME) .

#####################################################################
# Rules for verification, formatting, linting, testing and cleaning #
#####################################################################

.PHONY: tidy
tidy:
	@go mod tidy
	@mkdir -p $(REPO_ROOT)/.ci/hack && cp $(GARDENER_HACK_DIR)/.ci/* $(GARDENER_HACK_DIR)/generate-controller-registration.sh $(REPO_ROOT)/.ci/hack/ && chmod +xw $(REPO_ROOT)/.ci/hack/*
	@GARDENER_HACK_DIR=$(GARDENER_HACK_DIR) $(REPO_ROOT)/hack/update-github-templates.sh
	@cp $(GARDENER_HACK_DIR)/cherry-pick-pull.sh $(HACK_DIR)/cherry-pick-pull.sh && chmod +xw $(HACK_DIR)/cherry-pick-pull.sh
	@cp $(GARDENER_HACK_DIR)/sast.sh $(HACK_DIR)/sast.sh && chmod +xw $(HACK_DIR)/sast.sh

.PHONY: clean
clean:
	@$(shell find ./example -type f -name "controller-registration.yaml" -exec rm '{}' \;)
	@$(shell find ./example -type f -name "extension-shoot-dns-service.yaml" -exec rm '{}' \;)
	@bash $(GARDENER_HACK_DIR)/clean.sh ./cmd/... ./pkg/... ./test/...

.PHONY: check-generate
check-generate:
	@bash $(GARDENER_HACK_DIR)/check-generate.sh $(REPO_ROOT)

.PHONY: check
check: $(GOIMPORTS) $(GOLANGCI_LINT) $(HELM)
	@bash $(GARDENER_HACK_DIR)/check.sh --golangci-lint-config=./.golangci.yaml ./cmd/... ./pkg/... ./test/...
	@bash $(GARDENER_HACK_DIR)/check-charts.sh ./charts

.PHONY: generate
generate: $(CONTROLLER_GEN) $(GEN_CRD_API_REFERENCE_DOCS) $(HELM) $(MOCKGEN) $(YQ) $(VGOPATH) $(EXTENSION_GEN) $(KUBECTL)
	@VGOPATH=$(VGOPATH) REPO_ROOT=$(REPO_ROOT) GARDENER_HACK_DIR=$(GARDENER_HACK_DIR) bash $(GARDENER_HACK_DIR)/generate-sequential.sh ./charts/... ./cmd/... ./pkg/... ./test/... ./example/...
	@./hack/prepare-operator-extension.sh
	$(MAKE) format

.PHONY: format
format: $(GOIMPORTS) $(GOIMPORTSREVISER)
	@bash $(GARDENER_HACK_DIR)/format.sh ./cmd ./pkg ./test

.PHONY: sast
sast: $(GOSEC)
	@./hack/sast.sh

.PHONY: sast-report
sast-report: $(GOSEC)
	@./hack/sast.sh --gosec-report true

.PHONY: test
test: $(GINKGO)
	@bash $(GARDENER_HACK_DIR)/test.sh ./cmd/... ./pkg/...

.PHONY: test-cov
test-cov:
	@bash $(GARDENER_HACK_DIR)/test-cover.sh ./cmd/... ./pkg/...

.PHONY: test-clean
test-clean:
	@bash $(GARDENER_HACK_DIR)/test-cover-clean.sh

.PHONY: test-integration-lifecycle
test-integration-lifecycle: $(REPORT_COLLECTOR) $(SETUP_ENVTEST)
	@bash $(GARDENER_HACK_DIR)/test-integration.sh ./test/integration/lifecycle/...

.PHONY: verify
verify: check format test test-integration-lifecycle sast

.PHONY: verify-extended
verify-extended: check-generate check format test-cov test-clean test-integration-lifecycle sast-report
