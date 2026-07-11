#!/usr/bin/with-contenv bashio
# Map add-on options onto the env vars server.js reads.
export HA_URL="$(bashio::config 'ha_url')"
export HA_TOKEN="$(bashio::config 'token')"
# Works whether dash_paths is a comma-separated string (current schema)
# or a YAML list (pre-1.3 installs).
export DASH_PATHS="$(bashio::config 'dash_paths' | paste -sd, -)"
export INTERVAL_SECONDS="$(bashio::config 'interval_seconds')"
export WIDTH="$(bashio::config 'width')"
export HEIGHT="$(bashio::config 'height')"
export DARK_MODE="$(bashio::config 'dark_mode')"
export RELOAD_MINUTES="$(bashio::config 'reload_minutes')"
export PORT=8080

if bashio::config.is_empty 'token'; then
    bashio::log.fatal "Set a long-lived access token in the add-on configuration."
    exit 1
fi

bashio::log.info "Capturing: ${DASH_PATHS}"
exec node /app/server.js
