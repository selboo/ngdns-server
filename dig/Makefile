
DOCKER_REGISTRY ?= selboo/dig
DIG_VERSION ?= "9.7.7 9.8.8 9.9.3 9.9.13 9.10.8 9.11.20 9.14.12 9.16.4 9.17.2"

build:
	@for var in $(shell echo ${DIG_VERSION}); do \
		docker build --build-arg dig_version=$$var -t $(DOCKER_REGISTRY):$$var . ;\
	done

base:
	docker build -f Dockerfile.base -t $(DOCKER_REGISTRY):base .
	docker push $(DOCKER_REGISTRY):base

.PHONY: build