# Usage:
# make            install BC wrapper
# make remove     uninstall BC wrapper

SHELL := /bin/bash
repo_dir := $(abspath $(dir $(MAKEFILE_LIST)))
install_dir := $(shell grep -Po '^.*?\K/home/$(USER)[^:]*' <<< $(PATH) || echo /usr/local/bin)

install: _check_permission
	$(info Installing...)
ifneq ($(wildcard /usr/local/src/bc_wrapper/bc_wrapper.sh),)
	@printf '\033[1;35mPrevious installation detected!\033[m\n'
	@$(MAKE) --no-print-directory remove
endif
	@mkdir -p /usr/local/src/bc_wrapper /usr/local/lib/bc_wrapper
	@cp $(repo_dir)/bc_wrapper.sh /usr/local/src/bc_wrapper/
	@cp $(repo_dir)/lib/custom_functions.bc /usr/local/lib/bc_wrapper/
	@gcc $(repo_dir)/lib/write_to_STDIN.c -o /usr/local/lib/bc_wrapper/write_to_STDIN
	@update-alternatives --quiet --install $(install_dir)/bc bc /usr/local/src/bc_wrapper/bc_wrapper.sh 10
	@update-alternatives --quiet --set bc /usr/local/src/bc_wrapper/bc_wrapper.sh
ifeq ($(shell command -v xfce4-terminal &>/dev/null),)
	@mkdir -p /usr/local/etc/bc_wrapper/xfce4/terminal/
	@cp $(repo_dir)/etc/bc_wrapper*.svg /usr/local/etc/bc_wrapper/
	@cp $(repo_dir)/etc/terminalrc /usr/local/etc/bc_wrapper/xfce4/terminal/
	@if [[ -e /home/$(USER)/.local/share/applications/ && "$(install_dir)" == *home* ]]; then \
		cp $(repo_dir)/etc/bc_wrapper.desktop /home/$(USER)/.local/share/applications/; \
	else \
		cp $(repo_dir)/etc/bc_wrapper.desktop /usr/share/applications/; \
	fi
else
	@printf "\033[1;35mTo use BC as application \033[3mxfce4-terminal\033[23m should be installed.\033[m\n"
	@printf "\033[1;35mIf you decide to install it, rerun make...\033[m\n"
endif
	@printf '\033[1;35mInstallation finished. If \033[3mbc\033[23m is not updated, '
	@printf 'restart the shell or check:\n\033[mupdate-alternatives --display bc\n'

remove: _check_permission
	@printf 'Removing... '
	@update-alternatives --quiet --remove bc /usr/local/src/bc_wrapper/bc_wrapper.sh
	@rm -rf /usr/local/src/bc_wrapper /usr/local/lib/bc_wrapper
ifeq ($(shell command -v xfce4-terminal &>/dev/null),)
	@rm -rf /usr/local/etc/bc_wrapper
	@rm -f /home/$(USER)/.local/share/applications/bc_wrapper.desktop
	@rm -f /usr/share/applications/bc_wrapper.desktop
endif
	@echo Done

_check_permission:
	@if [ ! -w /usr/local/bin ]; then \
		printf "\033[1;31mPermission denied\033[m\n"; \
		exit 4; \
	fi

