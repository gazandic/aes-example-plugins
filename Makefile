PLUGIN_DIR ?= .

DOCKER_REGISTRY ?= localhost:31000
DOCKER_IMAGE ?= $(DOCKER_REGISTRY)/aes-custom:$(shell git describe --tags --always --dirty --exclude '*-hf.*')


AES_VERSION ?= 3.0.0
AES_IMAGE ?= docker.io/datawire/aes:$(AES_VERSION)

all: .docker.stamp
.PHONY: all

aes-abi.txt: .var.AES_IMAGE
	@printf "AES_VERSION=$(AES_VERSION)\n"
	@printf "AES_IMAGE=$(AES_IMAGE)\n"
	docker run --rm --entrypoint=cat $(AES_IMAGE) /ambassador/aes-abi.txt > $@
%.mk: %.txt
	{ \
		sed -n 's/^# *_*/AES_/p' < $<; \
		echo AES_GOENV=$$(sed -En 's/^# *([A-Z])/\1/p' < $<); \
	} > $@
%.pkgs.txt: %.txt
	grep -v '^#' < $< > $@
-include aes-abi.mk

go.DOCKER_IMAGE = golang:$(AES_GOVERSION)$(if $(filter 2,$(words $(subst ., ,$(AES_GOVERSION)))),.0)

# Since the GOPATH must match amb-sidecar, we *always* compile in
# Docker, so that we can put it at an arbitrary path without fuss.
go.GOBUILD  = docker exec -i $(shell docker ps -q -f label=component=plugin-builder) go build -trimpath

container-rsync = rsync --blocking-io -e 'docker exec -i'
container.ID = $(shell docker ps -q -f label=component=plugin-builder)

.var.AES_IMAGE: .var.%: FORCE
	@echo $($*) > .tmp$@ && if cmp -s $@ .tmp$@; then rm -f .tmp$@ || true; else cp -f .tmp$@ $@; fi
Dockerfile: Dockerfile.in .var.AES_IMAGE
	sed 's,@AES_IMAGE@,$(AES_IMAGE),' < $< > $@
.docker.stamp: $(patsubst $(PLUGIN_DIR)/%.go,%.so,$(wildcard $(PLUGIN_DIR)/*)) Dockerfile
	docker build -t $(DOCKER_IMAGE) .
	date > $@

push: .docker.stamp
	docker push $(DOCKER_IMAGE)
.PHONY: push

download-docker:
	docker pull $(go.DOCKER_IMAGE) || docker run --rm --entrypoint=true $(go.DOCKER_IMAGE)
.PHONY: download-docker

build-container:
ifeq "$(container.ID)" ""
	docker build -t plugin-builder --build-arg CUR_DIR=$(CURDIR) --build-arg AES_GOVERSION=$(AES_GOVERSION)$(if $(filter 2,$(words $(subst ., ,$(AES_GOVERSION)))),.0) --build-arg UID=$(shell id -u) build/
	docker run --rm -d --env-file=${CURDIR}/aes-abi.mk plugin-builder
endif

sync: build-container
	$(container-rsync) --exclude-from=${CURDIR}/build/sync-excludes.txt -r . $(container.ID):$(CURDIR)
	$(container-rsync) -r $(firstword $(subst :, ,$(shell go env GOPATH)))/pkg/mod/cache/download/ $(container.ID):/mnt/goproxy/

vendor: FORCE
	go mod vendor
.my-abi.pkgs.txt: vendor
	<vendor/modules.txt grep -e '^[^#]' -e '^# ' | grep -B1 '^[^#]' | sed -n 's/^# //p' >$@
.common-pkgs.txt: aes-abi.pkgs.txt .my-abi.pkgs.txt
	@bash -c 'comm -12 <(<.my-abi.pkgs.txt cut -d" " -f1|sort) <(< aes-abi.pkgs.txt cut -d" " -f1|sort)' > $@
version-check: .common-pkgs.txt aes-abi.pkgs.txt
	@bash -c 'diff -u <(grep -F -f $< aes-abi.pkgs.txt) <(grep -F -f $< .my-abi.pkgs.txt)' || { \
		printf '\nKey:\n  -version in AES\n  +version in Plugin\n\nERROR: dependency versions do not match AES\n\n'; \
		false; \
	}
.PHONY: version-check

%.so: $(PLUGIN_DIR)/%.go download-docker version-check sync
	$(go.GOBUILD) -buildmode=plugin -o $@ $<
	$(container-rsync) -a $(container.ID):${CURDIR}/$(@F) .

clean:
	rm -f -- *.so .docker.stamp .common-pkgs.txt .tmp.* .var.* Dockerfile aes-abi*
ifneq "$(container.ID)" ""
	docker kill $(container.ID)
endif
.PHONY: clean

.DELETE_ON_ERROR:
.NOTPARALLEL:
.PHONY: FORCE
