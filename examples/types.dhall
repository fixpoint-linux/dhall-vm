-- types.dhall — a tour of the language's value types.
--
-- Demonstrates: a record type annotation with a matching literal, Some/None
-- optionals, arithmetic + comparisons, a union with merge, and List/map.
-- The top-level is a record, so it serializes to JSON and YAML. (No TOML
-- snapshot: the `None` optional serializes to `null`, which TOML cannot
-- represent.)
--
-- Expected to-json:
--   {"arithmetic":5,"comparisons":{"eq":true,"lt":true},"mapped":[2,4,6],"optional":{"none":null,"some":42},"origin":{"x":0,"y":0},"scalars":{"flag":true,"greeting":"hello","n":10},"status":"active"}
--
-- Expected to-yaml:
--   arithmetic: 5
--   comparisons:
--     eq: true
--     lt: true
--   mapped:
--     - 2
--     - 4
--     - 6
--   optional:
--     none: null
--     some: 42
--   origin:
--     x: 0
--     y: 0
--   scalars:
--     flag: true
--     greeting: hello
--     n: 10
--   status: active
let origin = ({ x = 0, y = 0 } : { x : Natural, y : Natural })
in  let st = merge { Active = \(_ : Bool) -> "active",
                     Inactive = \(_ : Bool) -> "inactive" }
                   (< Active = True | Inactive : Bool >)
in  {
      scalars = { n = 10, flag = True, greeting = "hello" },
      optional = { some = Some 42, none = None Natural },
      arithmetic = 2 + 3,
      comparisons = { eq = 1 == 1, lt = 2 < 5 },
      mapped = List/map Natural Natural (\(x : Natural) -> x * 2) [ 1, 2, 3 ],
      status = st,
      origin = origin
    }
