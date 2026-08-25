# This file contains the build system commands configuration
# and environment variables
include mk/config.mk

# Build system dependencies
include mk/depends.mk

all: $(BUILD)/harddrive.img

live:
	-$(FUMOUNT) $(BUILD)/filesystem/ || true
	-$(FUMOUNT) /tmp/redox_installer/ || true
	rm -f $(BUILD)/redox-live.iso
	$(MAKE) $(BUILD)/redox-live.iso

popsicle: $(BUILD)/redox-live.iso
	popsicle-gtk $(BUILD)/redox-live.iso

image:
	-$(FUMOUNT) $(BUILD)/filesystem/ || true
	-$(FUMOUNT) /tmp/redox_installer/ || true
	rm -f $(BUILD)/harddrive.img $(BUILD)/redox-live.iso
	$(MAKE) all

rebuild:
	-$(FUMOUNT) $(BUILD)/filesystem/ || true
	-$(FUMOUNT) /tmp/redox_installer/ || true
	rm -rf $(BUILD)/repo.tag $(BUILD)/harddrive.img $(BUILD)/redox-live.iso
	$(MAKE) all

# To tell that it's not safe
# to execute the cookbook binary
NOT_ON_PODMAN?=0

clean:
ifeq ($(PODMAN_BUILD),1)
ifneq ("$(wildcard $(CONTAINER_TAG))","")
	$(PODMAN_RUN) make $@
else
	$(info will not run cookbook clean as container is not built)
	$(MAKE) clean PODMAN_BUILD=0 NOT_ON_PODMAN=1 SKIP_CHECK_TOOLS=1
endif # CONTAINER_TAG
else
ifneq ($(NOT_ON_PODMAN),1)
	$(MAKE) repo_clean
	-$(FUMOUNT) $(BUILD)/filesystem/ || true
	-$(FUMOUNT) /tmp/redox_installer/ || true
endif # NOT_ON_PODMAN
	rm -rf repo
	rm -rf $(BUILD) $(PREFIX)
	$(MAKE) fstools_clean
endif # PODMAN_BUILD

distclean:
ifeq ($(PODMAN_BUILD),1)
ifneq ("$(wildcard $(CONTAINER_TAG))","")
	$(PODMAN_RUN) make $@
else
	$(info will not run cookbook unfetch as container is not built)
	$(MAKE) distclean PODMAN_BUILD=0 NOT_ON_PODMAN=1 SKIP_CHECK_TOOLS=1
endif # CONTAINER_TAG
else
ifneq ($(NOT_ON_PODMAN),1)
	$(MAKE) fetch_clean
endif # NOT_ON_PODMAN
	$(MAKE) clean NOT_ON_PODMAN=1
endif # PODMAN_BUILD

pull:
	git pull
	rm -f $(FSTOOLS_TAG)

cookbook:
	rm -f $(FSTOOLS_TAG)
	$(MAKE) $(FSTOOLS_TAG)

repo: $(BUILD)/repo.tag

repo_clean: c.--all

fetch_clean: u.--all

# Podman build recipes and vars
include mk/podman.mk

# Disk Imaging and Cookbook tools
include mk/fstools.mk

# Cross compiler recipes
include mk/prefix.mk

# Repository maintenance
include mk/repo.mk

# Build an independent Flash 1.0 runtime from the immutable public-automation
# baseline. The migration parity harness uses this binary before it exercises
# the workspace candidate, so this acquisition path must not load candidate
# sources, Cargo configuration, or an ambient fsh.
FLASH_AUTOMATION_BASELINE_COMMIT=134635a5e1282b5d8455a4b2aeb754be5a3a77c1
FLASH_AUTOMATION_BASELINE_TREE=6c4a3645e7ac1c019411eb8f1de620a5a5028cb0
FLASH_AUTOMATION_RUST_TOOLCHAIN=1.97.1
FLASH_BOOTSTRAP_DIR?=build/flash-bootstrap/$(FLASH_AUTOMATION_BASELINE_COMMIT)
FLASH_AUTOMATION_TOOLS_DIR?=build/flash-automation-tools

.PHONY: flash-automation-tools
flash-automation-tools:
	@set -eu; \
	case "$$(uname -s)-$$(uname -m)" in \
		Darwin-arm64) platform=darwin-aarch64; rg_package=ripgrep-15.2.0-aarch64-apple-darwin ;; \
		Linux-x86_64) platform=linux-x86_64; rg_package=ripgrep-15.2.0-x86_64-unknown-linux-musl ;; \
		*) echo "flash automation tools: unsupported host $$(uname -s)-$$(uname -m)" >&2; exit 1 ;; \
	esac; \
	manifest=ci/automation-tools.json; \
	field() { python3 -c 'import json,sys; value=json.load(open(sys.argv[1], encoding="utf-8")); print(value["tools"][sys.argv[2]]["assets"][sys.argv[3]][sys.argv[4]])' "$$manifest" "$$1" "$$platform" "$$2"; }; \
	digest() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$$1" | cut -d ' ' -f 1; elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$$1" | cut -d ' ' -f 1; else echo "flash automation tools: sha256sum or shasum is required" >&2; exit 1; fi; }; \
	work="$$(mktemp -d "$${TMPDIR:-/tmp}/flash-automation-tools.XXXXXX")"; \
	trap 'rm -rf "$$work"' EXIT HUP INT TERM; \
	for tool in taplo jq rg; do \
		url="$$(field "$$tool" url)"; \
		expected="$$(field "$$tool" sha256)"; \
		curl --fail --location --retry 3 --proto '=https' --output "$$work/$$tool.asset" "$$url"; \
		observed="$$(digest "$$work/$$tool.asset")"; \
		test "$$observed" = "$$expected" || { echo "flash automation tools: $$tool digest differs" >&2; exit 1; }; \
	done; \
	gzip -dc "$$work/taplo.asset" > "$$work/taplo"; \
	cp "$$work/jq.asset" "$$work/jq"; \
	mkdir "$$work/rg"; \
	tar -xzf "$$work/rg.asset" -C "$$work/rg"; \
	cp "$$work/rg/$$rg_package/rg" "$$work/rg-bin"; \
	chmod 0755 "$$work/taplo" "$$work/jq" "$$work/rg-bin"; \
	test "$$($$work/taplo --version)" = 'taplo 0.10.0'; \
	case "$$($$work/jq --version)" in jq-1.7.1|jq-1.7.1-apple) ;; *) echo 'flash automation tools: jq version differs' >&2; exit 1 ;; esac; \
	test "$$($$work/rg-bin --version | sed -n '1s/ (rev .*)$$//p')" = 'ripgrep 15.2.0'; \
	destination="$(FLASH_AUTOMATION_TOOLS_DIR)/$$platform"; \
	mkdir -p "$$destination/bin"; \
	cp "$$work/taplo" "$$destination/bin/taplo.new"; \
	cp "$$work/jq" "$$destination/bin/jq.new"; \
	cp "$$work/rg-bin" "$$destination/bin/rg.new"; \
	cp "$$manifest" "$$destination/manifest.json.new"; \
	mv "$$destination/bin/taplo.new" "$$destination/bin/taplo"; \
	mv "$$destination/bin/jq.new" "$$destination/bin/jq"; \
	mv "$$destination/bin/rg.new" "$$destination/bin/rg"; \
	mv "$$destination/manifest.json.new" "$$destination/manifest.json"; \
	echo "flash automation tools: $$destination/bin"

.PHONY: flash-bootstrap
flash-bootstrap:
	@set -eu; \
	repository="$$(pwd -P)"; \
	destination="$(FLASH_BOOTSTRAP_DIR)"; \
	work="$$(mktemp -d "$${TMPDIR:-/tmp}/flash-bootstrap.XXXXXX")"; \
	trap 'rm -rf "$$work"' EXIT HUP INT TERM; \
	git clone --quiet --no-hardlinks --no-checkout "$$repository" "$$work/source"; \
	git -C "$$work/source" checkout --quiet --detach "$(FLASH_AUTOMATION_BASELINE_COMMIT)"; \
	test "$$(git -C "$$work/source" rev-parse HEAD)" = "$(FLASH_AUTOMATION_BASELINE_COMMIT)"; \
	test "$$(git -C "$$work/source" rev-parse 'HEAD^{tree}')" = "$(FLASH_AUTOMATION_BASELINE_TREE)"; \
	test -z "$$(git -C "$$work/source" status --porcelain --untracked-files=all)"; \
	test "$$(sed -n 's/^channel = "\([^"]*\)"/\1/p' "$$work/source/components/flash/rust-toolchain.toml")" = "$(FLASH_AUTOMATION_RUST_TOOLCHAIN)"; \
	host_cargo="$$(rustup which --toolchain "$(FLASH_AUTOMATION_RUST_TOOLCHAIN)" cargo)"; \
	host_rustc="$$(rustup which --toolchain "$(FLASH_AUTOMATION_RUST_TOOLCHAIN)" rustc)"; \
	( \
		unset CARGO_BUILD_RUSTC_WRAPPER CARGO_TARGET_DIR RUSTC_WRAPPER RUSTFLAGS; \
		cd "$$work/source/components/flash"; \
		CARGO_INCREMENTAL=0 \
		RUSTC="$$host_rustc" \
		"$$host_cargo" build --locked --bin fsh --target-dir "$$work/target"; \
	); \
	test "$$($$work/target/debug/fsh --version)" = "fsh 1.0.0"; \
	if command -v sha256sum >/dev/null 2>&1; then \
		digest="$$(sha256sum "$$work/target/debug/fsh" | cut -d ' ' -f 1)"; \
	elif command -v shasum >/dev/null 2>&1; then \
		digest="$$(shasum -a 256 "$$work/target/debug/fsh" | cut -d ' ' -f 1)"; \
	else \
		echo "flash bootstrap: sha256sum or shasum is required" >&2; \
		exit 1; \
	fi; \
	mkdir -p "$$destination"; \
	cp "$$work/target/debug/fsh" "$$destination/fsh.new"; \
	chmod 0755 "$$destination/fsh.new"; \
	printf '%s\n' \
		'{' \
		'  "schema": 1,' \
		'  "source_commit": "$(FLASH_AUTOMATION_BASELINE_COMMIT)",' \
		'  "source_tree": "$(FLASH_AUTOMATION_BASELINE_TREE)",' \
		'  "rust_toolchain": "$(FLASH_AUTOMATION_RUST_TOOLCHAIN)",' \
		'  "version": "fsh 1.0.0",' \
		"  \"binary_sha256\": \"$$digest\"" \
		'}' > "$$destination/manifest.json.new"; \
	mv "$$destination/fsh.new" "$$destination/fsh"; \
	mv "$$destination/manifest.json.new" "$$destination/manifest.json"; \
	echo "flash bootstrap: $$destination/fsh ($$digest)"

# Disk images
include mk/disk.mk

# Emulation recipes
include mk/qemu.mk

env: prefix FORCE $(CONTAINER_TAG)
ifeq ($(PODMAN_BUILD),1)
	$(PODMAN_RUN) make $@
else
	export PATH="$(PREFIX_PATH):$$PATH" && \
	bash
endif

setenv: FORCE
	@echo export ARCH='$(ARCH)'
	@echo export BOARD='$(BOARD)'
	@echo export CONFIG_NAME='$(CONFIG_NAME)'
	@echo BUILD='$(BUILD)'

export RUST_GDB=gdb-multiarch # Necessary when debugging for another architecture than the host
GDB_KERNEL_FILE=recipes/core/kernel/target/$(TARGET)/build/kernel.sym
gdb: FORCE
	rust-gdb $(GDB_KERNEL_FILE) --eval-command="target remote :1234"

# This target allows debugging a userspace application without requiring gdbserver running inside
# the VM. Because gdb doesn't know when the userspace application is scheduled by the kernel and as
# it stops the entire VM rather than just the userspace application that the user wants to debug,
# connecting to a gdbserver running inside the VM is highly encouraged when possible. This target
# should only be used when the application to debug runs early during boot before the network stack
# has started or you need to debug the interaction between the application and the kernel.
# tl;dr: DO NOT USE THIS TARGET UNLESS YOU HAVE TO
gdb-userspace: FORCE
	rust-gdb $(GDB_APP_FILE) --eval-command="add-symbol-file $(GDB_KERNEL_FILE)" --eval-command="target remote :1234"

# An empty target
FORCE:

# Wireshark
wireshark: FORCE
	wireshark $(BUILD)/network.pcap

KPROF_KERNEL_BINARY?=recipes/core/profiling-kernel/target/$(TARGET)/build/kernel
KPROF_KERNEL_SYM?=build/flamegraph/$(TARGET)-kernel-syms.txt
KPROF_OUTPUT_TXT?=build/$(ARCH)/$(CONFIG_NAME)/filesystem/home/root/kprof.txt
KPROF_PERF_SVG?=build/flamegraph/$(TARGET)-$(CONFIG_NAME)-kflamegraph.svg
# XXX: This assumes the TSC is invariant, that the value for cpu0 is the same as for all other CPUs, and that the value from ACPI actually reflects the TSC rate. It also only works on Linux.
KPROF_CPU_GHZ?=$(shell (cat /sys/devices/system/cpu/cpu0/acpi_cppc/nominal_freq || echo 3400) | xargs echo "0.001 *" | bc)
# See https://gitlab.redox-os.org/redox-os/kprofiling/-/blob/master/src/main.rs?ref_type=heads#L16-L18
# Set e.g. to "xo" to show individual instruction offsets
KPROF_OPTIONS?=_

flamegraph:
	mkdir -p build/flamegraph && \
	make mount && \
	nm -CS $(KPROF_KERNEL_BINARY) >$(KPROF_KERNEL_SYM) && \
	redox-kprofiling $(KPROF_OUTPUT_TXT) $(KPROF_KERNEL_SYM) $(KPROF_OPTIONS) $(KPROF_CPU_GHZ) | inferno-collapse-perf | inferno-flamegraph > $(KPROF_PERF_SVG) && \
	make unmount
