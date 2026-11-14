FROM ruby:3.4.12-slim-bookworm

RUN apt-get update -qq && apt-get install --no-install-recommends -y \
    build-essential git libpq-dev libvips curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /rails
ENV BUNDLE_PATH=/usr/local/bundle
COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs 4 && bundle exec bootsnap precompile --gemfile

COPY . .
ENTRYPOINT ["/rails/bin/docker-entrypoint"]
EXPOSE 3000
CMD ["bin/rails", "server", "-b", "0.0.0.0"]
