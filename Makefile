# Usage:
# make           # install BC wrapper
# make remove    # uninstall BC wrapper

dir_path := $(abspath $(dir $(MAKEFILE_LIST)))

install: warn
	$(info Installing...)
	@mkdir -p $(dir_path)/bin
	@gcc $(dir_path)/lib/write_to_STDIN.c -o $(dir_path)/bin/write_to_STDIN
ifneq ($(wildcard /home/$(USER)/.local/bin/),)
	@sudo update-alternatives --install /home/$(USER)/.local/bin/bc bc $(dir_path)/bc.bash 10
	@sudo update-alternatives --set bc $(dir_path)/bc.bash
else
	@sudo update-alternatives --install /usr/local/bin/bc bc $(dir_path)/bc.bash 10
	@sudo update-alternatives --set bc $(dir_path)/bc.bash
endif

remove: warn
	$(info Removing...)
	@sudo update-alternatives --remove bc $(dir_path)/bc.bash

warn:
	@printf "\033[1;35mIf \033[3mupdate-alternatives\033[23m don't change \033[3mbc\033[23m, restart the shell.\033[m\n"

