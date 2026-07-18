#!/usr/bin/env bash
set -Eeu

# Default Alpine image has wget (but not curl)

# Dockerfile has this
# HEALTHCHECK --interval=1s --timeout=1s --retries=5 --start-period=5s CMD ./config/healthcheck.sh

# --interval=S     time until 1st healthcheck
# --timeout=S      fail if single healthcheck takes longer than this
# --retries=N      number of tries until container considered unhealthy
# --start-period=S grace period when healthcheck fails dont count towards --retries

# The client's readiness delegates to the spooler server (Prober#ready?), so this
# probe also proves the server is reachable before the tests exec into this container.
readonly PORT="${CYBER_DOJO_SPOOLER_CLIENT_PORT}"
readonly READY_LOG_FILENAME=/tmp/ready.log

wget http://0.0.0.0:${PORT}/ready -q -O - >> "${READY_LOG_FILENAME}" 2>&1
echo >> "${READY_LOG_FILENAME}"  # add a newline

# keep only most recent 500 lines
tail -n500 "${READY_LOG_FILENAME}" > "${READY_LOG_FILENAME}.tmp"
mv "${READY_LOG_FILENAME}.tmp" "${READY_LOG_FILENAME}"
