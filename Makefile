.PHONY: install verify check test-vm
USER_NAME ?= josh
install:
	USER_NAME='$(USER_NAME)' sh ./install.sh
verify:
	USER_NAME='$(USER_NAME)' sh ./verify.sh
check:
	sh tests/static.sh
test-vm:
	sh tests/vm.sh
