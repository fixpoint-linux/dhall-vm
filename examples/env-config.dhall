-- env-config.dhall — an example of environment-variable imports.
--
-- `env:HOME` reads the $HOME variable at load time, so the value depends
-- on the host. This example is TYPE-CHECK ONLY (no .expected.* snapshots):
-- it exists to show `env:` imports and to be a smoke test that they
-- typecheck and normalize. The resolved value is host-specific, so the
-- output is not pinned.
--
--   $ dhall typecheck examples/env-config.dhall   # exit 0
--   $ dhall normalize examples/env-config.dhall   # prints { home = "/home/you", note = "resolved at load time" }
{
  home = env:HOME,
  note = "resolved at load time"
}
