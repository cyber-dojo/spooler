FROM ghcr.io/cyber-dojo/sinatra-base:1a1d65f@sha256:31bfb1e5cbc25d4b37e0dfea2e460d4ecdaf8062bfc5b70b6a28c40211daea61 AS base
# The FROM statement above is typically set via an automated pull-request from the sinatra-base repo
LABEL maintainer=jon@jaggersoft.com

# The spooler persists its buffer in an embedded SQLite database (ADR section 7),
# reached via the sqlite3 gem. On Alpine (musl) there is no precompiled gem, so
# the gem compiles its vendored SQLite amalgamation statically into the native
# extension. The build toolchain is only needed to compile it: install as a
# virtual package, build, then drop it. Re-add libgcc for the libgcc_s the
# compiled extension links at runtime (the other libs it needs are provided by
# ruby).
RUN apk add --no-cache --virtual .sqlite3-build-deps build-base \
 && gem install sqlite3 \
 && apk del .sqlite3-build-deps \
 && apk add --no-cache libgcc

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
