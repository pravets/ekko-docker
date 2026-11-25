IMAGE ?= ekko-docker:v0.8.30
BASE_IMAGE ?= ekkoye8888/hermes-web-ui:v0.8.30
RUNTIME_UID ?= $(shell id -u)
RUNTIME_GID ?= $(shell id -g)

.PHONY: build verify lint check-base
build:
	docker build --build-arg BASE_IMAGE=$(BASE_IMAGE) --build-arg RUNTIME_UID=$(RUNTIME_UID) --build-arg RUNTIME_GID=$(RUNTIME_GID) -t $(IMAGE) .

verify:
	RUNTIME_UID=$(RUNTIME_UID) RUNTIME_GID=$(RUNTIME_GID) ./scripts/verify.sh $(IMAGE)

lint:
	hadolint Dockerfile
	bash -n scripts/verify.sh scripts/check-base.sh

check-base:
	./scripts/check-base.sh --list
