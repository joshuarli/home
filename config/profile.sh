case $- in *i*)
	if [ "$(tty 2>/dev/null)" = /dev/tty1 ] && [ -z "${WAYLAND_DISPLAY:-}" ] &&
		id -Gn 2>/dev/null | tr ' ' '\n' | grep -qx seat; then
		/usr/local/bin/home-session
	fi
	;;
esac
