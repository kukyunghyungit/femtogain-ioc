# femtogain-motd.sh — shown at every interactive login (ssh / console).
# Installed as /etc/profile.d/femtogain-motd.sh  (symlink to this file).
# Disable for one user:  touch ~/.no_femtogain_motd
case "$-" in *i*) ;; *) return 0 2>/dev/null || exit 0 ;; esac
[ -e "$HOME/.no_femtogain_motd" ] && return 0
command -v femtogainctl >/dev/null 2>&1 || return 0

echo
echo "============== Femto Gain Controller Rev.2  ($(hostname)) =============="
femtogainctl status 2>/dev/null
echo
echo "----------------------- femtogainctl 명령 요약 -----------------------"
femtogainctl help 2>/dev/null | sed -n '2,$p' | sed 's/^#   /  /'
echo "--------------------------------------------------------------------"
echo "  매뉴얼: /usr/local/epics/iocs/femtogain/README.md   (이 메시지 끄기: touch ~/.no_femtogain_motd)"
echo
