#!/usr/bin/env bash
set -Eeu

export ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/bin/lib.sh"
source "${ROOT_DIR}/bin/echo_env_vars.sh"

show_help()
{
    local -r MY_NAME=$(basename "${BASH_SOURCE[0]}")
    cat <<- EOF

    Use: ${MY_NAME} {server}

    Options:
      -h      Show this help
      server  Build the spooler server image

    Example:
      ${MY_NAME} server

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
      ;;
    '')
      show_help
      stderr "no argument - must be 'server'"
      exit_non_zero
      ;;
    *)
      show_help
      stderr "argument is '${1:-}' - must be 'server'"
      exit_non_zero
  esac
}

build_image()
{
  check_args "$@"
  exit_non_zero_unless_installed docker
  # shellcheck disable=SC2046
  export $(echo_env_vars)
  containers_down
  remove_old_images
  docker --log-level=ERROR compose build server

  local -r image_name="${CYBER_DOJO_SPOOLER_IMAGE}:${CYBER_DOJO_SPOOLER_TAG}"
  local -r sha_in_image=$(docker run --rm --entrypoint="" "${image_name}" sh -c 'echo -n ${COMMIT_SHA}' 2>/dev/null)
  if [ "${COMMIT_SHA}" != "${sha_in_image}" ]; then
    echo "ERROR: unexpected env-var inside image ${image_name}"
    echo "expected: 'COMMIT_SHA=${COMMIT_SHA}'"
    echo "  actual: 'COMMIT_SHA=${sha_in_image}'"
    exit_non_zero
  fi

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
}

build_image "$@"
