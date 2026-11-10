import Config

config :networth,
  # PBKDF2-HMAC-SHA256 iterations, OWASP 2023 recommendation.
  password_iterations: 600_000,
  token_ttl_days: 30

if config_env() == :test do
  config :networth, password_iterations: 1_000
  config :logger, level: :warning
end
