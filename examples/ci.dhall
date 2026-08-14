-- ci.dhall — an example CI pipeline configuration.
--
-- Demonstrates: a `let` binding a shared step list reused by two jobs,
-- a `merge` over a union used as a branch condition, a List of records
-- (jobs), and a List of records (matrix).
--
-- Expected to-json:
--   {"jobs":[{"image":"golang:1.22","name":"build","steps":["git clone","go build"],"timeout":3600},{"image":"node:20","name":"test","steps":["npm ci","npm test"],"timeout":1800}],"matrix":[{"os":"ubuntu-22.04"},{"os":"macos-14"}],"name":"dhall-c ci","on":"push"}
--
-- Expected to-yaml:
--   jobs:
--     - image: golang:1.22
--       name: build
--       steps:
--         - git clone
--         - go build
--       timeout: 3600
--     - image: node:20
--       name: test
--       steps:
--         - npm ci
--         - npm test
--       timeout: 1800
--   matrix:
--     - os: ubuntu-22.04
--     - os: macos-14
--   name: dhall-c ci
--   on: push
--
-- Expected to-toml (top level is a record):
--   jobs = [{ image = "golang:1.22", name = "build", steps = ["git clone", "go build"], timeout = 3600 }, { image = "node:20", name = "test", steps = ["npm ci", "npm test"], timeout = 1800 }]
--   matrix = [{ os = "ubuntu-22.04" }, { os = "macos-14" }]
--   name = "dhall-c ci"
--   on = "push"
let build_steps = [ "git clone", "go build" ]
in  let test_steps = [ "npm ci", "npm test" ]
in  let trigger = < push : Text | tag : Text | always : Bool >
in  let when = merge { push = \(_ : Text) -> "push",
                      tag  = \(_ : Text) -> "tag",
                      always = \(_ : Bool) -> "always" }
                    (< push = "refs/heads/main" | tag : Text | always : Bool >)
in  {
      name = "dhall-c ci",
      on = when,
      jobs = [
        { name = "build", image = "golang:1.22", steps = build_steps, timeout = 3600 },
        { name = "test",  image = "node:20",     steps = test_steps,  timeout = 1800 }
      ],
      matrix = [ { os = "ubuntu-22.04" }, { os = "macos-14" } ]
    }
