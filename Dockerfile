# syntax=docker/dockerfile:1
FROM ruby:3.4.12-slim-bookworm AS base
WORKDIR /rails
ENV BUNDLE_PATH=/usr/local/bundle
RUN apt-get update -qq && apt-get install --no-install-recommends -y libpq5 libvips curl ca-certificates && rm -rf /var/lib/apt/lists/*

FROM base AS application
RUN apt-get update -qq && apt-get install --no-install-recommends -y build-essential git libpq-dev && rm -rf /var/lib/apt/lists/*
COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs 4 && bundle exec bootsnap precompile --gemfile
COPY . .
ENTRYPOINT ["/rails/bin/docker-entrypoint"]
EXPOSE 3000
CMD ["bin/rails", "server", "-b", "0.0.0.0"]

FROM node:24.19.0-bookworm-slim AS node
FROM application AS ci
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx && npm ci && npx playwright install --with-deps chromium
ENV RAILS_ENV=test CI=true
CMD ["bin/ci"]

FROM application AS production-build
ENV RAILS_ENV=production BUNDLE_WITHOUT=development:test BUNDLE_DEPLOYMENT=1
RUN bundle config set --local without 'development test' && bundle install && bundle clean --force && rm -rf /usr/local/bundle/cache /root/.bundle/cache
RUN bundle exec bootsnap precompile app/ lib/
RUN SECRET_KEY_BASE_DUMMY=1 bin/rails assets:precompile

FROM base AS production
ENV RAILS_ENV=production BUNDLE_WITHOUT=development:test BUNDLE_DEPLOYMENT=1 RAILS_LOG_TO_STDOUT=1 RAILS_SERVE_STATIC_FILES=1 PORT=3000
RUN groupadd --system --gid 1000 rails && useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
COPY --from=production-build /usr/local/bundle /usr/local/bundle
COPY --from=production-build --chown=rails:rails /rails /rails
RUN install -d -o rails -g rails storage tmp log storage/files tmp/pids
USER 1000:1000
ENTRYPOINT ["/rails/bin/docker-entrypoint"]
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s CMD curl --fail --silent http://127.0.0.1:3000/up || exit 1
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]

# Keep the default docker compose build suitable for local bind mounts.
FROM application AS development
