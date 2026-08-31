-- Dhakefile.dhall — build the dhall-c interpreter (Zig) + docs site with dhake.
--
-- The interpreter is the Zig port (zig/src, canonical).  The former C
-- implementation (src/*.c + the cosmocc APE *.com binaries it built) was
-- removed once the port went fully green; the committed APE binaries
-- (dhall.com, dhall.com.dbg, dhall-lsp.com, bench.com, …) remain only as
-- frozen artifacts — dhall.com.dbg is the differential oracle used by
-- zig/dhall_diff.sh — and are NOT rebuilt from source.  The docs site
-- (fixpointlinux.org/dhall-c) is an Elm app built via elm + scripts/ssg.mjs:
--
--     vendor/mfe-framework -> vendor/@mfe -> dist/elm.js -> dist/index.html
--
-- Run with dhake from this directory:
--
--     ./vendor/dhake/dhake.com                    # default: `all` (Zig CLI + LSP)
--     ./vendor/dhake/dhake.com all                # build the Zig binaries
--     ./vendor/dhake/dhake.com test               # run the offline test suite
--     ./vendor/dhake/dhake.com dist/index.html    # build the docs site
--     ./vendor/dhake/dhake.com --list             # list all targets

let Action =
      < Shell : Text
      | Copy : { from : Text, to : Text }
      | Mkdir : < Plain : Text | Parents : { path : Text, parents : Bool } >
      | Rm : < Plain : Text | Recursive : { path : Text, recursive : Bool } >
      | Touch : Text
      | Move : { from : Text, to : Text }
      | Symlink : { from : Text, to : Text }
      | Chmod : { path : Text, mode : Text }
      | Echo : Text
      | Env : { key : Text, value : Text }
      | Run : { argv : List Text }
      >

let Target = { deps : List Text, phony : Bool, recipe : List Action }

-- Zig interpreter modules shared by the CLI (main.zig) and the LSP (lsp.zig).
let zigCore =
      [ "zig/src/arena.zig"
      , "zig/src/ast.zig"
      , "zig/src/bignum.zig"
      , "zig/src/builtins.zig"
      , "zig/src/dhall.zig"
      , "zig/src/http.zig"
      , "zig/src/import.zig"
      , "zig/src/lexer.zig"
      , "zig/src/normalize.zig"
      , "zig/src/parser.zig"
      , "zig/src/sha256.zig"
      , "zig/src/ssrf.zig"
      , "zig/src/typecheck.zig"
      ]

in  { targets =
        -- `all` and the default: build the Zig CLI + LSP server.
        [ { mapKey = "all"
          , mapValue =
              { deps = [ "zig-out/bin/dhall", "zig-out/bin/dhall-lsp" ]
              , phony = True
              , recipe = [] : List Action
              }
          }

        -- ─── Zig targets ────────────────────────────────────────────────────
        -- The CLI and LSP server are built with the Zig 0.16 self-host
        -- toolchain.  Outputs are not hash-pinned (zig build-exe bytes are
        -- toolchain-version-specific); deps list the Zig modules so edits
        -- trigger rebuilds.
        , { mapKey = "zig-out/bin/dhall"
          , mapValue =
              { deps = [ "zig/src/main.zig", "zig/src/serialize.zig" ] # zigCore
              , phony = False
              , recipe =
                  [ < Shell =
                        "zig build-exe -O ReleaseSafe -lc "
                      ++ "-femit-bin=zig-out/bin/dhall zig/src/main.zig"
                    >
                  ]
              }
          }
        , { mapKey = "zig-out/bin/dhall-lsp"
          , mapValue =
              { deps = [ "zig/src/lsp.zig", "zig/src/lsp_json.zig" ] # zigCore
              , phony = False
              , recipe =
                  [ < Shell =
                        "zig build-exe -O ReleaseSafe -lc -fstrip "
                      ++ "-femit-bin=zig-out/bin/dhall-lsp zig/src/lsp.zig"
                    >
                  ]
              }
          }

        -- Offline test suite: build the Zig binaries, then run the golden
        -- differential harnesses (dhall_diff + u2/u3/u4), the interpreter CLI
        -- tests, and the LSP end-to-end checks.
        , { mapKey = "test"
          , mapValue =
              { deps = [ "all" ]
              , phony = True
              , recipe =
                  [ < Shell = "bash zig/dhall_diff.sh" >
                  , < Shell = "bash zig/u2_lexer_diff.sh" >
                  , < Shell = "bash zig/u3_parser_diff.sh" >
                  , < Shell = "bash zig/u4_ast_diff.sh" >
                  , < Shell =
                        "./tests/run.sh zig-out/bin/dhall "
                      ++ "&& ./tests/roundtrip.sh zig-out/bin/dhall "
                      ++ "&& ./tests/examples.sh zig-out/bin/dhall "
                      ++ "&& ./tests/cli.sh zig-out/bin/dhall"
                    >
                  , < Shell = "bash tests/lsp.sh zig-out/bin/dhall-lsp" >
                  , < Shell = "zig test -lc zig/src/ssrf.zig" >
                  , < Shell = "zig test -lc zig/src/union_test.zig" >
                  ]
              }
          }

        , { mapKey = "clean"
          , mapValue =
              { deps = []
              , phony = True
              , recipe =
                  [ < Rm = < Recursive = { path = "zig-out", recursive = True } > > ]
              }
          }

        -- ─── docs site (fixpoint design components) ─────────────────────────
        -- The docs site is an Elm app (src/Main.elm) rendered against the shared
        -- Fixpoint.* design package (vendor/design) + the @mfe/framework shell
        -- (vendor/mfe-framework). Pipeline, mirroring datalog-dafsa:
        --
        --   vendor/mfe-framework -> vendor/@mfe -> dist/elm.js -> dist/index.html
        --
        -- The `dist/index.html` target produces the full multi-route site
        -- (dist/index.html + dist/{language,cli,api,playground}/index.html + the
        -- wasm/CodeMirror assets copied by scripts/ssg.mjs from docs/). Run it
        -- explicitly with `dhake dist/index.html`. The Zig interpreter is the
        -- default build; the site does not require emscripten (wasm is committed
        -- to docs/ and copied by the ssg).
        , { mapKey = "mfe-framework"
          , mapValue =
              { deps = []
              , phony = True
              , recipe =
                  [ < Shell = "cd vendor/mfe-framework && npm ci && npm run build" >
                  ]
              }
          }
        , { mapKey = "vendor-mfe"
          , mapValue =
              { deps = [ "mfe-framework" ]
              , phony = True
              , recipe =
                  [ < Rm = < Recursive = { path = "vendor/@mfe", recursive = True } > >
                  , < Mkdir = < Parents = { path = "vendor/@mfe/core", parents = True } > >
                  , < Mkdir = < Parents = { path = "vendor/@mfe/framework", parents = True } > >
                  , < Shell =
                        "cp vendor/mfe-framework/packages/core/dist/*.js vendor/@mfe/core/"
                    >
                  , < Shell =
                        "cp vendor/mfe-framework/packages/framework/dist/*.js vendor/@mfe/framework/"
                    >
                  ]
              }
          }
        , { mapKey = "dist/elm.js"
          , mapValue =
              { deps = [ "src/Main.elm", "elm.json", "vendor/design/src" ]
              , phony = False
              , recipe =
                  [ < Shell =
                        "node_modules/elm/bin/elm make src/Main.elm --output=dist/elm.js --optimize"
                    >
                  ]
              }
          }
        , { mapKey = "dist/index.html"
          , mapValue =
              { deps =
                  [ "dist/elm.js"
                  , "vendor-mfe"
                  , "shell/index.html"
                  , "shell/pages.js"
                  , "shell/shell.js"
                  , "shell/templates/dhallc-landing.html"
                  , "shell/templates/dhallc-language.html"
                  , "shell/templates/dhallc-cli.html"
                  , "shell/templates/dhallc-api.html"
                  , "shell/templates/dhallc-playground.html"
                  , "shell/templates/fixpoint.html"
                  , "shell/mfe/dhallc-page.js"
                  , "shell/mfe/playground-element.js"
                  , "scripts/ssg.mjs"
                  , "docs/dhall.js"
                  , "docs/dhall-lsp.js"
                  , "docs/playground-ui.js"
                  , "docs/vendor/codemirror.min.js"
                  , "docs/vendor/codemirror.css"
                  , "docs/vendor/codemirror-simple.js"
                  , "docs/vendor/codemirror-lint.js"
                  , "docs/vendor/codemirror-lint.css"
                  , "docs/vendor/dhall-mode.js"
                  , "docs/examples/server.dhall"
                  , "docs/examples/ci.dhall"
                  , "docs/examples/types.dhall"
                  ]
              , phony = False
              , recipe = [ < Shell = "node scripts/ssg.mjs" > ]
              }
          }
        ]
      , default = "all"
      }
