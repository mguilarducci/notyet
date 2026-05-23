# --- build stage: full toolchain (compiles + holds dev deps for migrations) ---
FROM ghcr.io/gleam-lang/gleam:v1.16.0-erlang-alpine AS build

WORKDIR /app
COPY gleam.toml manifest.toml ./
RUN gleam deps download
COPY . .
RUN gleam export erlang-shipment

# --- runtime stage: slim Erlang, production shipment only ---
FROM erlang:29-alpine AS runtime

WORKDIR /app
COPY --from=build /app/build/erlang-shipment /app

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["run"]
