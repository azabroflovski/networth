# Production image: the release built in one stage, run in a slim Debian.
#   docker build -t networth .
#   docker run --rm -e DATABASE_URL=... networth bin/networth eval "Networth.Release.migrate()"
#   docker run -p 4000:4000 -e DATABASE_URL=... networth
ARG ELIXIR_VERSION=1.20.4
ARG OTP_VERSION=28.5.0.8
ARG DEBIAN_VERSION=trixie-20261027-slim

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION} AS build

ENV MIX_ENV=prod
WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force

# Dependencies first, so code changes reuse this layer.
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
COPY config/config.exs config/
RUN mix deps.compile

COPY lib lib
COPY priv priv
COPY config/runtime.exs config/
RUN mix release

FROM debian:${DEBIAN_VERSION}

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates \
  && rm -rf /var/lib/apt/lists/* \
  && sed -i '/en_US.UTF-8/s/^# //' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 MIX_ENV=prod PORT=4000
WORKDIR /app
COPY --from=build --chown=nobody:root /app/_build/prod/rel/networth ./
USER nobody

EXPOSE 4000
CMD ["/app/bin/networth", "start"]
