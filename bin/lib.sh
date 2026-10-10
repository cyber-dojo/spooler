
stderr()
{
  local -r message="${1}"
  >&2 echo "ERROR: ${message}"
}

exit_non_zero()
{
  exit 42
}

installed()
{
  local -r dependent="${1}"
  if hash "${dependent}" 2> /dev/null; then
    true
  else
    false
  fi
}

exit_non_zero_unless_installed()
{
  for dependent in "$@"
  do
    if ! installed "${dependent}" ; then
      stderr "${dependent} is not installed"
      exit_non_zero
    fi
  done
}

containers_down()
{
  docker compose down --remove-orphans --volumes
}

remove_old_images()
{
  # Tagging images from the commit-sha builds up many images over time,
  # which slows down image listing. Remove old spooler images continuously.
  echo Removing old images
  # grep exits non-zero when the machine holds no spooler image, eg one whose
  # images have just been cleared, so an empty list must not end the build.
  local -r dil=$(docker image ls --format "{{.Repository}}:{{.Tag}}" | grep spooler || true)
  remove_all_but_current "${dil}" "${CYBER_DOJO_SPOOLER_IMAGE}"
  remove_all_but_current "${dil}" cyberdojo/spooler
}

# Keeps this commit's tag, which names the build just made. Every older tag
# goes, and an earlier build whose last tag was one of those goes with it.
remove_all_but_current()
{
  local -r docker_image_ls="${1}"
  local -r name="${2}"
  # Its own name, not image_name: bash locals are dynamically scoped, and
  # build_image declares image_name readonly before calling this.
  local tagged_name
  for tagged_name in $(echo "${docker_image_ls}" | grep "${name}:" || true)
  do
    if [ "${tagged_name}" != "${name}:${CYBER_DOJO_SPOOLER_TAG}" ]; then
      docker image rm --force "${tagged_name}" || echo "  skipped ${tagged_name} (in use)"
    fi
  done
}

exit_non_zero_unless_file_exists()
{
  local -r filename="${1}"
  if [ ! -f "${filename}" ]; then
    stderr "${filename} does not exist"
    exit_non_zero
  fi
}

service_container()
{
  # Echo the container id of the given docker-compose service within this
  # repo's project. Resolving by label (not a fixed container_name) lets
  # several spooler runs, and runs in sibling repos, coexist without
  # colliding. The project defaults to spooler when not exported.
  local -r service="${1}"
  docker ps \
    --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME:-spooler}" \
    --filter "label=com.docker.compose.service=${service}" \
    --format '{{.ID}}'
}

echo_warnings()
{
  local -r SERVICE_NAME="${1}"
  local -r DOCKER_LOG=$(docker logs "${CONTAINER_NAME}" 2>&1)
  if echo "${DOCKER_LOG}" | grep --quiet "warning" ; then
    echo "Warnings in ${SERVICE_NAME} container"
    echo "${DOCKER_LOG}"
  fi
}
