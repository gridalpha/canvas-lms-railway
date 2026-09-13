# Canvas LMS for Railway.
#
# Instructure publishes no current application image — the `instructure/canvas-lms`
# Docker Hub tags were last pushed in 2019 — so the app is built here from the
# upstream repository, following upstream's own Dockerfile.production recipe, with
# the Railway-specific configuration layered on top.

ARG RUBY=3.4
FROM instructure/ruby-passenger:3.4-jammy

# Which upstream ref to build.
#
# Pinned rather than floating: the `prod` branch — Instructure's pointer at the
# release running in their own estate — carries a `ui/features/discovery_page` that
# imports `@instructure/platform-alerts`, and its root `package.json` never declares
# that package, so a clean checkout cannot resolve it and the webpack stage fails.
# The newest release tag declares the dependency and does not ship that feature.
ARG CANVAS_REF=release/2026-05-20.143

# Build all ~30 UI locales (1) or English only (0). All-locales roughly doubles the
# webpack stage; English-only keeps a first build inside a sane window. Change this
# to 1 in a fork if you need the other languages.
ARG CANVAS_ALL_LOCALES=0

ARG RUBY
ARG POSTGRES_CLIENT=16
ENV APP_HOME=/usr/src/app/
ENV RAILS_ENV=production
ENV SASS_STYLE=compressed
ENV RAILS_LOAD_ALL_LOCALES=${CANVAS_ALL_LOCALES}
ENV NGINX_MAX_UPLOAD_SIZE=10g
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US.UTF-8
ENV LC_CTYPE=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ARG CANVAS_RAILS=8.0
ENV CANVAS_RAILS=${CANVAS_RAILS}

ENV NODE_MAJOR=20
ENV GEM_HOME=/home/docker/.gem/$RUBY
ENV PATH=${APP_HOME}bin:$GEM_HOME/bin:$PATH
ENV BUNDLE_APP_CONFIG=/home/docker/.bundle

WORKDIR $APP_HOME

USER root
RUN mkdir -p /etc/apt/keyrings \
  && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
  && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list \
  && printf 'path-exclude /usr/share/doc/*\npath-exclude /usr/share/man/*' > /etc/dpkg/dpkg.cfg.d/01_nodoc \
  && echo "deb http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
  && curl -sS https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add - \
  && add-apt-repository ppa:git-core/ppa -ny \
  && apt-get update -qq \
  && apt-get install -qqy --no-install-recommends \
       nodejs \
       libxmlsec1-dev \
       python3-lxml \
       python-is-python3 \
       libicu-dev \
       libidn11-dev \
       parallel \
       postgresql-client-$POSTGRES_CLIENT \
       tzdata \
       unzip \
       pbzip2 \
       git \
       build-essential \
  && rm -rf /var/lib/apt/lists/* \
  && mkdir -p /home/docker/.gem/ruby/$RUBY_MAJOR.0

RUN gem install bundler --no-document -v 2.5.10 \
  && find $GEM_HOME ! -user docker | xargs chown docker:docker
RUN npm install -g npm@9.8.1 && npm cache clean --force

ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN corepack enable && corepack prepare yarn@1.19.1 --activate

# Upstream source. A shallow single-branch clone keeps this to a fraction of the
# 2 GB history, and the .git directory is dropped so it never reaches the image.
RUN git clone --depth 1 --single-branch --branch "$CANVAS_REF" \
      https://github.com/instructure/canvas-lms.git /tmp/canvas \
  && (cd /tmp/canvas && git rev-parse HEAD > /tmp/canvas-revision) \
  && rm -rf /tmp/canvas/.git \
  && cp -a /tmp/canvas/. "$APP_HOME" \
  && mv /tmp/canvas-revision "$APP_HOME/CANVAS_REVISION" \
  && rm -rf /tmp/canvas \
  && chown -R docker:docker "$APP_HOME"

# Railway configuration: every file here is ERB and reads its values from the
# container environment, so one image serves any deployment.
COPY --chown=docker:docker config/ $APP_HOME/config/
COPY --chown=docker:docker railway/ $APP_HOME/railway/

# Canvas writes its Rails log to log/<env>.log; Railway reads stdout.
RUN ln -sf /dev/stdout "$APP_HOME/log/production.log" \
  && ln -sf /dev/stdout "$APP_HOME/log/delayed_job.log" \
  && chmod +x "$APP_HOME/railway/entrypoint.sh" \
  && bash -n "$APP_HOME/railway/entrypoint.sh" \
  && ruby -c "$APP_HOME/railway/jobs_health.rb" \
  && ruby -c "$APP_HOME/railway/puma.rb" \
  && ruby -c "$APP_HOME/config/environments/production-local.rb" \
  && command -v psql && command -v pg_isready

USER docker

RUN mkdir -p tmp/files log public/dist

ENV COMPILE_ASSETS_BRAND_CONFIGS=0
ENV COMPILE_ASSETS_NPM_INSTALL=0
ENV COMPILE_ASSETS_API_DOCS=0

# Canvas' asset build fans out with Parallel.processor_count, which reads the host's
# 48 cores rather than the container's quota.
ENV CANVAS_BUILD_CONCURRENCY=4
# In production mode Canvas also builds an unminified development bundle purely as a
# ?optimized_js=0 fallback. Skipping it, and sourcemaps with it, halves the webpack
# stage and ships nothing the deployment serves.
ENV JS_BUILD_NO_FALLBACK=1
ENV SKIP_SOURCEMAPS=1
# Do not fail the whole build on a webpack warning.
ENV WEBPACK_PEDANTIC=0

RUN unset RUBY && bundle config --global build.nokogiri --use-system-libraries && \
  bundle config --global build.ffi --enable-system-libffi && \
  bundle install --jobs 8

RUN (yarn install --frozen-lockfile || yarn install --frozen-lockfile --network-concurrency 1) && \
  bin/rails canvas:compile_assets --trace && \
  rm -rf node_modules /home/docker/.cache/yarn

# Fail the build rather than the container if a compiled bundle is missing.
RUN test -d public/dist/webpack-production && ls public/dist/webpack-production | head -5

ENV CANVAS_ROLE=web
CMD ["/usr/src/app/railway/entrypoint.sh"]
