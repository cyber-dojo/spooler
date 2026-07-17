FROM ghcr.io/cyber-dojo/sinatra-base:1a1d65f@sha256:31bfb1e5cbc25d4b37e0dfea2e460d4ecdaf8062bfc5b70b6a28c40211daea61 AS base
# The FROM statement above is typically set via an automated pull-request from the sinatra-base repo
LABEL maintainer=jon@jaggersoft.com

ARG COMMIT_SHA
ENV COMMIT_SHA=${COMMIT_SHA}

ARG APP_DIR=/spooler
ENV APP_DIR=${APP_DIR}

# Default port so the image's probes work in a bare `docker run`; the deployed
# stack overrides this via its env file.
ENV CYBER_DOJO_SPOOLER_PORT=4590

RUN adduser                        \
  -D               `# no password` \
  -G nogroup       `# no group`    \
  -H               `# no home dir` \
  -s /sbin/nologin `# no shell`    \
  -u 19664         `# user-id`     \
  spooler          `# user-name`

WORKDIR ${APP_DIR}/source
COPY source/server/ .
USER spooler
HEALTHCHECK --interval=1s --timeout=1s --retries=5 --start-period=5s CMD ./config/healthcheck.sh
ENTRYPOINT ["/sbin/tini", "-g", "--"]
CMD [ "./config/up.sh" ]
