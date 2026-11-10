import Config

config :networth,
  # PBKDF2-HMAC-SHA256 iterations, OWASP 2023 recommendation.
  password_iterations: 600_000,
  token_ttl_days: 30,
  # {attempts, window in ms}: failed logins per email, all logins per client IP.
  login_limits: [per_email: {5, :timer.minutes(15)}, per_ip: {20, :timer.minutes(5)}]

if config_env() == :test do
  config :networth, password_iterations: 1_000
  config :logger, level: :warning
end
