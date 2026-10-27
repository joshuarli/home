.PHONY: install verify check
USER_NAME ?=
install:
	USER_NAME='$(USER_NAME)' sh ./install.sh
verify:
	USER_NAME='$(USER_NAME)' sh ./verify.sh
check:
	sh -n install.sh verify.sh build/dwl.sh config/home-session
