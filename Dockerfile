FROM ghcr.io/cyber-dojo/sinatra-base:4d448af@sha256:d2d3fd0451afc5954ea4433e41f6f17ad6ad856bf607c9cd23dd4cf9c32b6ce8 AS base
# The FROM statement above is typically set via an automated pull-request from the sinatra-base repo
LABEL maintainer=jon@jaggersoft.com

# The spooler persists its buffer in an embedded SQLite database (ADR section 7),
# reached via the sqlite3 gem. On Alpine (musl) there is no precompiled gem, so
# the gem compiles its vendored SQLite amalgamation statically into the native
# extension. The build toolchain is only needed to compile it: install as a
# virtual package, build, then drop it. Re-add libgcc for the libgcc_s the
# compiled extension links at runtime (the other libs it needs are provided by
# ruby).
#
# The workflow caches the bare image (this base stage) by a hash of this
# stage's instructions (comments and blank lines aside), so this unpinned gem
# is as new as the last change to those instructions. To pick up a newer one,
# eg a security fix, bump GEM_REFRESH.
ARG GEM_REFRESH=1
RUN apk add --no-cache --virtual .sqlite3-build-deps build-base \
 && gem install sqlite3 \
 && apk del .sqlite3-build-deps \
 && apk add --no-cache libgcc

# path_coverage measures which paths through each decision and method the
# tests take, alongside SimpleCov's line and branch coverage. It is used only
# by the server test suite (test/server/config/coverage.rb). It is pinned to
# keep the image reproducible.
RUN gem install --no-document path_coverage --version 0.7.2

ARG APP_DIR=/spooler
ENV APP_DIR=${APP_DIR}

RUN adduser                        \
  -D               `# no password` \
  -G nogroup       `# no group`    \
  -H               `# no home dir` \
  -s /sbin/nologin `# no shell`    \
  -u 19664         `# user-id`     \
  spooler          `# user-name`

# Created as root, before USER, so the spooler user cannot add, remove or
# rename files in the source dir.
WORKDIR ${APP_DIR}/source
USER spooler

# The stage above, base, is the bare image: Ruby, its gems, the OS packages
# and the spooler user it runs as, with no source code. The stage below adds the source
# code, making the deployed image. Built with --target base it is the bare
# image the server tests run in (bin/run_tests_bare.sh); built with
# --build-context base=<that bare image>, the deployed image is built FROM
# the very bare image the tests ran in (.github/workflows/main.yml).
FROM base

ARG COMMIT_SHA
ENV COMMIT_SHA=${COMMIT_SHA}

# Owned by root, so the spooler user it runs as cannot change its own code.
COPY --chown=root:root source/server/ .
HEALTHCHECK --interval=1s --timeout=1s --retries=5 --start-period=5s CMD ./config/healthcheck.sh
ENTRYPOINT ["/sbin/tini", "-g", "--"]
CMD [ "./config/up.sh" ]
