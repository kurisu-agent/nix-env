#!/usr/bin/env bash
# nix-env-zellij-status — emits zjstatus command field output for the topbar.
#
# Reads identity from $NIX_ENV_IDENTITY_FILE (default $HOME/.config/zellij/identity.json):
#   { "color": "<palette name>", "name": "<display>", "icon": "<grapheme>" }
# All fields optional. Missing/unknown color falls back to overlay0;
# missing name falls back to `hostname`; missing icon prints nothing.
#
# /tmp/zellij-conntype is rewritten by each consumer's shell init on every
# interactive shell boot (zellij captures env at session-creation time and
# never refreshes for re-attaches, so $SSH_CONNECTION inside a long-lived
# plugin lies after the next attach). Falls back to env vars when the
# tmpfile hasn't been written yet (very first attach).

export LANG=en_US.UTF-8

NIX_ENV_IDENTITY_FILE="${NIX_ENV_IDENTITY_FILE:-$HOME/.config/zellij/identity.json}"

palette() {
    case "${1:-}" in
        text)     printf "#CDD6F4" ;;
        subtext0) printf "#A6ADC8" ;;
        overlay0) printf "#6C7086" ;;
        pink)     printf "#F5C2E7" ;;
        mauve)    printf "#CBA6F7" ;;
        lavender) printf "#B4BEFE" ;;
        blue)     printf "#89B4FA" ;;
        sapphire) printf "#74C7EC" ;;
        sky)      printf "#89DCEB" ;;
        teal)     printf "#94E2D5" ;;
        green)    printf "#A6E3A1" ;;
        yellow)   printf "#F9E2AF" ;;
        peach)    printf "#FAB387" ;;
        red)      printf "#F38BA8" ;;
        *)        printf "#6C7086" ;;
    esac
}

conn_now() {
    if [ -r /tmp/zellij-conntype ]; then
        cat /tmp/zellij-conntype
    elif [ -n "${MOSH_CONNECTION:-}" ]; then echo mosh
    elif [ -n "${SSH_CONNECTION:-}" ]; then echo ssh
    elif [ "${DEVPOD:-}" = "true" ]; then echo devpod
    else echo local
    fi
}

info_field() {
    if [ -r "$NIX_ENV_IDENTITY_FILE" ] && command -v jq >/dev/null 2>&1; then
        jq -r ".$1 // empty" "$NIX_ENV_IDENTITY_FILE" 2>/dev/null
    fi
}

case "${1:-}" in
    identity)
        name=$(info_field name)
        icon=$(info_field icon)
        color_name=$(info_field color)
        color=$(palette "${color_name:-overlay0}")
        [ -z "$name" ] && name=$(hostname -s 2>/dev/null || hostname)
        prefix=""
        [ -n "$icon" ] && prefix="$icon "
        printf "#[fg=%s,bold]%s%s" "$color" "$prefix" "$name"
        ;;
    user)
        # Optional `user` field on identity.json — typically the kart's
        # character. Renders blank when unset.
        u=$(info_field user)
        if [ -n "$u" ]; then printf "%s" "$u"; fi
        ;;
    conn_mosh)
        if [ "$(conn_now)" = "mosh" ]; then printf ' '; fi
        ;;
    conn_ssh)
        c=$(conn_now)
        if [ "$c" = "ssh" ] || [ "$c" = "devpod" ]; then printf ' '; fi
        ;;
    conn_local)
        if [ "$(conn_now)" = "local" ]; then printf ' '; fi
        ;;
    ip)
        ip -4 addr show 2>/dev/null | grep -oE 'inet ([0-9]+\.){3}[0-9]+' | awk '{print $2}' | grep -v '^127\.' | head -1
        ;;
    cpu)
        cpus=$(nproc)
        read -r u1 t1 < <(awk '/^cpu /{u=$2+$4; t=$2+$3+$4+$5+$6+$7+$8; print u, t}' /proc/stat)
        sleep 1
        read -r u2 t2 < <(awk '/^cpu /{u=$2+$4; t=$2+$3+$4+$5+$6+$7+$8; print u, t}' /proc/stat)
        if [ $((t2 - t1)) -gt 0 ]; then
            cpu_pct=$(( (u2 - u1) * 100 / (t2 - t1) ))
        else
            cpu_pct=0
        fi
        color="#6C7086"
        [ "$cpu_pct" -ge 50 ] && color="#F9E2AF"
        [ "$cpu_pct" -ge 80 ] && color="#F38BA8"
        printf "#[fg=%s] %-2s %s%%" "$color" "$cpus" "$cpu_pct"
        ;;
    mem)
        mem_total=$(free -m | awk '/Mem:/{print int(($2 + 1023) / 1024)}')
        mem_pct=$(free | awk '/Mem:/{printf "%d", $3*100/$2}')
        color="#6C7086"
        [ "$mem_pct" -ge 80 ] && color="#F9E2AF"
        [ "$mem_pct" -ge 95 ] && color="#F38BA8"
        printf "#[fg=%s] %-2s %s%%" "$color" "$mem_total" "$mem_pct"
        ;;
    network)
        read -r rx1 tx1 < <(awk '!/lo:/ && /:/{rx+=$2; tx+=$10} END{printf "%d %d\n", rx, tx}' /proc/net/dev)
        sleep 1
        read -r rx2 tx2 < <(awk '!/lo:/ && /:/{rx+=$2; tx+=$10} END{printf "%d %d\n", rx, tx}' /proc/net/dev)
        rx_rate=$(( (rx2 - rx1) / 1024 ))
        tx_rate=$(( (tx2 - tx1) / 1024 ))
        if [ "$rx_rate" -gt 1024 ]; then rx_str="$(( rx_rate / 1024 ))M"; else rx_str="${rx_rate}K"; fi
        if [ "$tx_rate" -gt 1024 ]; then tx_str="$(( tx_rate / 1024 ))M"; else tx_str="${tx_rate}K"; fi
        rx_color="#6C7086"; [ "$rx_rate" -ge 5120 ] && rx_color="#F9E2AF"
        tx_color="#6C7086"; [ "$tx_rate" -ge 5120 ] && tx_color="#F9E2AF"
        printf "#[fg=%s] %-4s #[fg=%s] %-4s" "$rx_color" "$rx_str" "$tx_color" "$tx_str"
        ;;
    *)
        echo "nix-env-zellij-status: unknown field '${1:-}'" >&2
        echo "  known: identity user conn_mosh conn_ssh conn_local ip cpu mem network" >&2
        exit 1
        ;;
esac
