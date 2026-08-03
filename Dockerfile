# syntax=docker/dockerfile:1
# check=error=true

# This Dockerfile is designed for production, not development. Use with Kamal or build'n'run by hand:
# docker build -t x_domain_prototype .
# docker run -d -p 80:80 -e RAILS_MASTER_KEY=<value from config/master.key> --name x_domain_prototype x_domain_prototype

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=3.3.5
FROM docker.io/library/node:20-bookworm-slim AS node
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base
COPY --from=node /usr/local/ /usr/local/

# Rails app lives here
WORKDIR /rails

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      curl \
      libjemalloc2 \
      libvips \
      sqlite3 \
      build-essential \
      git \
      libyaml-dev \
      pkg-config && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 \
      /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists/*

# Set production environment variables and enable jemalloc for reduced memory usage and latency.
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so" \
    GOVUK_APP_DOMAIN="dev.gov.uk" \
    GOVUK_WEBSITE_ROOT="https://dev.gov.uk" \
    HTTP_PORT=8080

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libvips libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems
COPY vendor/* ./vendor/
COPY Gemfile Gemfile.lock ./

RUN bundle install && \
    # Install JS dependencies for any git-sourced gems that ship their own
    # package.json (e.g. govuk_publishing_components). Bundler's git install
    # does not run npm install automatically the way a packaged gem release would,
    # so without this step, Sprockets link_tree directives that point into
    # that gem's own node_modules (e.g. govuk-frontend's rebrand images/fonts)
    # will fail with "link_tree argument must be a directory".
    #
    # IMPORTANT: this must run via `bundle exec ruby` (not a bare `ruby -e`),
    # and must use Bundler.load.specs (not Gem::Specification.each).
    # Git-sourced gems live under BUNDLE_PATH's bundler/gems/<name>-<sha>
    # directory, which is only visible once Bundler's own runtime/GEM_PATH
    # has been activated. A bare `ruby -e` only sees default RubyGems paths
    # and will silently find zero gems with a package.json - meaning this
    # step appears to succeed but never actually runs npm install for
    # govuk_publishing_components, and the later assets:precompile step
    # then fails with the link_tree error even though this step logged no error.
    bundle exec ruby -e ' \
      Bundler.load.specs.each do |spec| \
        pkg = File.join(spec.full_gem_path, "package.json"); \
        next unless File.exist?(pkg); \
        puts "Running npm install for #{spec.name} at #{spec.full_gem_path}"; \
        Dir.chdir(spec.full_gem_path) { system("npm install") || abort("npm install failed for #{spec.name}") }; \
      end \
    ' && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    # -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
    bundle exec bootsnap precompile -j 1 --gemfile

# Copy application code
COPY . .

RUN npm ci

# Confirm the files required by Sprockets are present
RUN test -f node_modules/sortablejs/Sortable.js && \
    test -f node_modules/accessible-autocomplete/dist/accessible-autocomplete.min.js && \
    test -f node_modules/accessible-autocomplete/dist/accessible-autocomplete.min.css

# Confirm the app's own asset directories (needed by manifest.js link_tree) exist
RUN test -d app/assets/builds

# Confirm the govuk_publishing_components gem's own node_modules/govuk-frontend
# rebrand assets exist now, so a failure here (not at assets:precompile) tells
# us immediately if the npm install step above did not run correctly.
RUN bundle exec ruby -e ' \
  spec = Bundler.load.specs.find { |s| s.name == "govuk_publishing_components" }; \
  abort("govuk_publishing_components gem not found") unless spec; \
  target = File.join(spec.full_gem_path, "node_modules/govuk-frontend/dist/govuk/assets/rebrand/images"); \
  abort("Missing directory: #{target}") unless Dir.exist?(target); \
  puts "OK: #{target} exists" \
'

# Precompile bootsnap code for faster boot times.
# -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
RUN bundle exec bootsnap precompile -j 1 app/ lib/

# Precompiling assets for production without requiring secret RAILS_MASTER_KEY
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile

# Final stage for app image
FROM base

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

# Copy built artifacts: gems, application
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Keep standard Cloud Run port mapping
EXPOSE 8080

# Boot Puma directly, routing requests directly to Rails
CMD ["./bin/rails", "server", "-b", "0.0.0.0", "-p", "8080"]