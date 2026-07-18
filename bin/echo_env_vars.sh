
echo_env_vars()
{
  # Set env-vars for this repo. The KEY=value lines echoed to stdout are
  # captured by the caller (build_image.sh) with `export $(echo_env_vars)`
  # for docker-compose variable substitution; the ports are also written to
  # .env, which docker-compose reads for substitution and injects into the
  # container via `env_file`.
  local -r sha="$(cd "${ROOT_DIR}" && git rev-parse HEAD)"
  if [[ ! -v COMMIT_SHA ]] ; then
    echo COMMIT_SHA="${sha}"  # --build-arg
  fi

  # Setup port env-vars in .env file using versioner.
  # versioner does not (yet) know the spooler, so its port is injected here;
  # remove this line once the spooler is registered in versioner.
  {
    echo "# This file is generated in bin/echo_env_vars.sh echo_env_vars()"
    echo "CYBER_DOJO_SPOOLER_PORT=4539"
    echo "CYBER_DOJO_SPOOLER_CLIENT_PORT=4538"
    docker run --rm cyberdojo/versioner 2> /dev/null | grep PORT
  } > "${ROOT_DIR}/.env"

  echo CYBER_DOJO_SPOOLER_SERVER_USER=spooler
  echo CYBER_DOJO_SPOOLER_CLIENT_USER=nobody
  echo CYBER_DOJO_SPOOLER_CLIENT_IMAGE=cyberdojo/spooler-client

  # This repo overrides
  local -r AWS_ACCOUNT_ID=244531986313
  local -r AWS_REGION=eu-central-1
  echo CYBER_DOJO_SPOOLER_IMAGE=${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/spooler
  echo CYBER_DOJO_SPOOLER_SHA="${sha}"
  echo CYBER_DOJO_SPOOLER_TAG="${sha:0:7}"
}
