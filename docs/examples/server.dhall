-- server.dhall — an example server configuration.
--
-- Demonstrates: a nested record (bind), a Text union with a payload
-- (log_level), a List Text (tags), and scalar fields.
--
-- Expected to-json:
--   {"bind":{"ip":"0.0.0.0","port":8080},"host":"example.com","log_level":{"INFO":"info"},"port":443,"retries":3,"tags":["web","api"],"timeout_ms":30000,"tls":true}
--
-- Expected to-yaml:
--   bind:
--     ip: 0.0.0.0
--     port: 8080
--   host: example.com
--   log_level:
--     INFO: info
--   port: 443
--   retries: 3
--   tags:
--     - web
--     - api
--   timeout_ms: 30000
--   tls: true
--
-- Expected to-toml (top level is a record):
--   host = "example.com"
--   port = 443
--   retries = 3
--   tags = ["web", "api"]
--   timeout_ms = 30000
--   tls = true
--   [bind]
--   ip = "0.0.0.0"
--   port = 8080
--   [log_level]
--   INFO = "info"
{
  host = "example.com",
  port = 443,
  tls = True,
  timeout_ms = 30000,
  retries = 3,
  log_level = < DEBUG : Text | INFO = "info" | WARN : Text | ERROR : Text >,
  bind = { ip = "0.0.0.0", port = 8080 },
  tags = [ "web", "api" ]
}
