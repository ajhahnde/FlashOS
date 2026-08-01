# Configuration file of the Podman commands

# Configuration variables for running make in Podman
## Tag the podman image $IMAGE_TAG
IMAGE_TAG?=redox-base
## Working Directory in Podman
CONTAINER_WORKDIR?=/mnt/redox

## Flag passed to the Podman volumes. :Z can be used only with SELinux
USE_SELINUX?=1
ifeq ($(USE_SELINUX),1)
PODMAN_VOLUME_FLAG=:Z
else
PODMAN_VOLUME_FLAG=
endif

# Cache layers to redox-os docker hub
PODMAN_CACHE=
PODMAN_CACHE_PATH?=docker.io/redoxos/$(IMAGE_TAG)-$(HOST_ARCH)

PODMAN_CACHE_PULL?=1
ifeq ($(PODMAN_CACHE_PULL),1)
PODMAN_CACHE+=--cache-from=$(PODMAN_CACHE_PATH)
endif

PODMAN_CACHE_PUSH?=0
ifeq ($(PODMAN_CACHE_PUSH),1)
PODMAN_CACHE+=--cache-to=$(PODMAN_CACHE_PATH)
endif

## Podman Home Directory
PODMAN_HOME=$(ROOT)/build/podman

# Detect whether the invoking shell has a real TTY on stdout.
# When running non-interactively (CI, scripts, IDE tools) there is no TTY;
# in that case omit --tty from podman and set CI=1 so that repo cook
# automatically disables its TUI and uses plain log output instead.
HAS_TTY := $(shell [ -t 1 ] && echo 1 || echo 0)

ifeq ($(HAS_TTY),1)
PODMAN_TTY_FLAGS=--interactive --tty
PODMAN_CI_OVERRIDE=
else
PODMAN_TTY_FLAGS=
PODMAN_CI_OVERRIDE=--env CI=1
endif

## Podman command with its many arguments
PODMAN_VOLUMES=--volume $(ROOT):$(CONTAINER_WORKDIR)$(PODMAN_VOLUME_FLAG) --volume $(PODMAN_HOME):/root$(PODMAN_VOLUME_FLAG)
PODMAN_ENV=--env PATH=/root/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin --env PODMAN_BUILD=0
PODMAN_CONFIG=--env ARCH=$(ARCH) --env BOARD=$(BOARD) --env CONFIG_NAME=$(CONFIG_NAME) --env FILESYSTEM_CONFIG=$(FILESYSTEM_CONFIG) --env PREFIX_BINARY=$(PREFIX_BINARY) \
               --env CI=$(CI) --env COOKBOOK_MAKE_JOBS=$(COOKBOOK_MAKE_JOBS) --env COOKBOOK_LOGS=$(COOKBOOK_LOGS) --env COOKBOOK_VERBOSE=$(COOKBOOK_VERBOSE) --env COOKBOOK_COMPRESSED=$(COOKBOOK_COMPRESSED) \
               --env REPO_APPSTREAM=$(REPO_APPSTREAM) --env REPO_BINARY=$(REPO_BINARY) --env REPO_NONSTOP=$(REPO_NONSTOP) --env REPO_OFFLINE=$(REPO_OFFLINE) --env TESTBIN=$(TESTBIN) \
			   --env HOSTED_REDOX=$(HOSTED_REDOX) --env PREFIX_USE_UPSTREAM_RUST_COMPILER=$(PREFIX_USE_UPSTREAM_RUST_COMPILER)
PODMAN_OPTIONS=--rm --workdir $(CONTAINER_WORKDIR) $(PODMAN_TTY_FLAGS) --cap-add SYS_ADMIN --device /dev/fuse --network=host --env TERM=$(TERM) --pids-limit=-1
PODMAN_RUN=podman run $(PODMAN_OPTIONS) $(PODMAN_VOLUMES) $(PODMAN_ENV) $(PODMAN_CONFIG) $(PODMAN_CI_OVERRIDE) $(IMAGE_TAG)

container_shell: build/container.tag
ifeq ($(PODMAN_BUILD),1)
	$(PODMAN_RUN) bash
else
	@echo PODMAN_BUILD=$(PODMAN_BUILD), please set it to 1 in mk/config.mk
endif

container_clean: FORCE
	rm -f build/container.tag
	@echo "If podman dir cannot be removed, remove with \"sudo rm\"."
	-rm -rf $(PODMAN_HOME) || true
	@echo "For complete clean of images and containers, use \"podman system reset\""
	-podman image rm --force $(IMAGE_TAG) || true

container_touch: FORCE
ifeq ($(PODMAN_BUILD),1)
	rm -f build/container.tag
	podman image exists $(IMAGE_TAG) || (echo "Image does not exist, it will be rebuilt during normal make."; exit 1)
	touch build/container.tag
else
	@echo PODMAN_BUILD=$(PODMAN_BUILD), container not required.
endif

container_kill: FORCE
	podman kill --latest --signal SIGKILL

## Must match the value of CONTAINER_TAG in config.mk
build/container.tag: $(CONTAINERFILE)
ifeq ($(PODMAN_BUILD),1)
	rm -f $@ $(FSTOOLS_TAG)
	-podman image rm --force $(IMAGE_TAG) || true
	mkdir -p $(PODMAN_HOME)
	@echo "Building Podman image. This may take some time."
	cat $(CONTAINERFILE) | podman build --file - $(PODMAN_VOLUMES) $(PODMAN_CACHE) --tag $(IMAGE_TAG)
	$(PODMAN_RUN) bash -e podman/rustinstall.sh
	mkdir -p build
	touch $@
	@echo "Podman ready!"
else
	@echo PODMAN_BUILD=$(PODMAN_BUILD), container not required.
endif

container_push: build/container.tag
	podman push $(IMAGE_TAG) $(PODMAN_CACHE_PATH)

KERNEL_PATH := recipes/core/kernel
KERNEL_PATH_SOURCE := $(ROOT)/$(KERNEL_PATH)/source
KERNEL_PATH_TARGET := $(ROOT)/$(KERNEL_PATH)/target/$(TARGET)

# TODO: make this work using `make debug.kernel` and remove this
kernel_debugger:
	@echo "Building and running gdbgui container..."
	podman build -t redox-kernel-debug - < $(ROOT)/podman/redox-gdb-containerfile
	podman run --rm -p 5000:5000 -it --name redox-gdb \
		-v "$(KERNEL_PATH_TARGET)/build/kernel.sym:/kernel.sym" \
		-v "$(KERNEL_PATH_SOURCE)/src:/src" \
		redox-kernel-debug --gdb-cmd "gdb -ex 'set confirm off' \
			-ex 'add-symbol-file /kernel.sym' \
			-ex 'target remote host.containers.internal:1234'"
