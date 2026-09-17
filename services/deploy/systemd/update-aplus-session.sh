#!/bin/sh
set -eu

environment_file=/etc/ai-passport/services.env
test -f "$environment_file"

printf 'New APLUS session_id: ' >&2
saved_tty=$(stty -g)
trap 'stty "$saved_tty"' EXIT HUP INT TERM
stty -echo
unset session_id
IFS= read -r session_id
stty "$saved_tty"
trap - EXIT HUP INT TERM
printf '\n' >&2

case "$session_id" in
    ''|*[!0-9a-fA-F]*)
        printf 'Invalid session_id: expected hexadecimal characters.\n' >&2
        exit 2
        ;;
esac

temporary_file=$(mktemp /etc/ai-passport/services.env.XXXXXX)
# Keep the session out of process arguments and exported environment variables.
# printf is a shell builtin; awk reads the value from the pipe before the file.
printf '%s\n' "$session_id" | awk '
    BEGIN { replaced = 0 }
    FILENAME == "-" { value = $0; next }
    /^APLUS_SESSION_ID=/ { print "APLUS_SESSION_ID=" value; replaced = 1; next }
    { print }
    END { if (!replaced) print "APLUS_SESSION_ID=" value }
' - "$environment_file" > "$temporary_file"
unset session_id
chmod 0600 "$temporary_file"
mv "$temporary_file" "$environment_file"

systemctl restart ai-passport-meal.service
systemctl is-active --quiet ai-passport-meal.service
printf 'Aplus session updated and meal service restarted.\n'
