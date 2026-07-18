#!/usr/bin/env bash
set -Eeu

export ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/bin/lib.sh"
source "${ROOT_DIR}/bin/echo_env_vars.sh"

show_help()
{
    local -r MY_NAME=$(basename "${BASH_SOURCE[0]}")
    cat <<- EOF

    Use: ${MY_NAME} {server|client}

    Options:
      -h      Show this help
      server  Build the spooler server image (local only)
      client  Build the spooler client image (local and CI workflow)

    Example:
      ${MY_NAME} client

EOF
}

check_args()
{
  case "${1:-}" in
    '-h' | '--help')
      show_help
      exit 0
      ;;
    'server')
      if [ -n "${CI:-}" ] ; then
        stderr "Inside CI workflow the server image comes from secure-docker-build.yml, not this script"
        exit_non_zero
      fi
      ;;
    'client')
      ;;
    '')
      show_help
      stderr "no argument - must be 'client' or 'server'"
      exit_non_zero
      ;;
    *)
      show_help
      stderr "argument is '${1:-}' - must be 'client' or 'server'"
      exit_non_zero
  esac
}

build_image()
{
  check_args "$@"
  local -r type="${1}" # {server|client}
  exit_non_zero_unless_installed docker
  # shellcheck disable=SC2046
  export $(echo_env_vars)
  containers_down

  if [ "${CI:-}" != 'true' ]; then
    # In the CI workflow the server image is built once by secure-docker-build.yml
    # and pulled by the 'Download docker image' job; do not remove or rebuild it.
    remove_old_images
    # Locally, both client and server tests need a server image.
    docker --log-level=ERROR compose build server
  fi

  if [ "${type}" == 'client' ]; then
    docker --log-level=ERROR compose build client
  fi

  local -r image_name="${CYBER_DOJO_SPOOLER_IMAGE}:${CYBER_DOJO_SPOOLER_TAG}"
  local -r sha_in_image=$(docker run --rm --entrypoint="" "${image_name}" sh -c 'echo -n ${COMMIT_SHA}' 2>/dev/null)
  if [ "${COMMIT_SHA}" != "${sha_in_image}" ]; then
    echo "ERROR: unexpected env-var inside image ${image_name}"
    echo "expected: 'COMMIT_SHA=${COMMIT_SHA}'"
    echo "  actual: 'COMMIT_SHA=${sha_in_image}'"
    exit_non_zero
  fi

  if [ "${type}" == 'server' ]; then
    # Create latest tag for image build cache
    docker --log-level=ERROR tag "${image_name}" "${CYBER_DOJO_SPOOLER_IMAGE}:latest"
    # Tag image-name for local development where the spooler name comes from echo_env_vars
    docker --log-level=ERROR tag "${image_name}" "cyberdojo/spooler:${CYBER_DOJO_SPOOLER_TAG}"
    echo
    echo "  echo CYBER_DOJO_SPOOLER_SHA=${CYBER_DOJO_SPOOLER_SHA}"
    echo "  echo CYBER_DOJO_SPOOLER_TAG=${CYBER_DOJO_SPOOLER_TAG}"
    echo
    echo "${image_name}"
    echo "cyberdojo/spooler:${CYBER_DOJO_SPOOLER_TAG}"
  fi
}

build_image "$@"
