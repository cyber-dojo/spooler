#!/usr/bin/env bash
set -Eeu

readonly MY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

readonly service_name=spooler
readonly dir=sqlite
readonly uid=19664
readonly username=spooler
readonly gid=65533
readonly group=nogroup

# The spooler keeps its durable buffer in an embedded SQLite database (ADR
# section 7) on a volume mounted at /${dir}, separate from saver's /cyber-dojo.
# On AWS this is an EBS host_path bind mount; standalone (via the commander
# repo) it is a docker volume. Either way the volume must exist and be writable
# by the spooler user before puma starts.

if [ ! -d /${dir} ]; then
  cmd="mkdir /${dir}"
  echo "ERROR"
  echo "The ${service_name} service needs to volume-mount /${dir}"
  echo "Please run:"
  echo "  \$ [sudo] ${cmd}"
  exit 1
fi

readonly probe="for-ownership"
if ! mkdir /${dir}/${probe} 2>/dev/null; then
  cmd="chown ${uid}:${gid} /${dir}"
  echo "ERROR"
  echo "The ${service_name} service needs write access to /${dir}"
  echo "username=${username} (uid=${uid})"
  echo "group=${group} (gid=${gid})"
  echo "Please run:"
  echo "  \$ [sudo] ${cmd}"
  exit 2
else
  rmdir /${dir}/${probe}
fi

readonly PORT="${CYBER_DOJO_SPOOLER_PORT}"

export RUBYOPT='-W2 --enable-frozen-string-literal'

puma \
  --port="${PORT}" \
  --config="${MY_DIR}/puma.rb"
