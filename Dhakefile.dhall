-- Dhakefile.dhall — Dhall-driven buildfile for the dhall-c interpreter,
-- replacing the old Makefile.  Run with dhake from this directory:
--
--     dhake               # build the default target (dhall.com)
--     dhake --list        # list all targets
--     dhake dhall.com     # build the interpreter
--     dhake bench         # build + run the benchmark
--     dhake test          # run the full test suite
--     dhake clean         # remove the built binaries
--
-- The source layout mirrors the former Makefile's SRC/BENCH_SRC/LSP_SRC/HDR
-- sets.  dhake (a Make-like build tool driven by Dhall) links this project's
-- interpreter core as its engine, so `dhake` and `make` drive the same
-- compiler; only the buildfile language differs.
--
-- ─── verified builds ────────────────────────────────────────────────────────
-- Each compile target pins its expected *output* hash (`hash`) and the expected
-- hash of every *source* dependency (`depsHash`).  The cosmocc APE output is
-- deterministic (same toolchain + sources + flags => identical bytes), so the
-- output pin is sound.  If a hash goes stale (edit a source, bump the
-- toolchain), rebuild with `dhake --warn-hash-mismatch` to print the actual
-- hashes and copy them into this file.
-- ───────────────────────────────────────────────────────────────────────────

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

let Target = { deps : List Text, phony : Bool, recipe : List Action
             , hash : Optional Text
             , depsHash : Optional (List { path : Text, hash : Text })
             }

-- Interpreter core (linked by main.c, bench.c and lsp.c alike) + shared
-- headers.  Matches the Makefile's SRC-minus-entrypoint / HDR sets.
let core =
      [ "src/arena.c"
      , "src/lexer.c"
      , "src/parser.c"
      , "src/ast.c"
      , "src/normalize.c"
      , "src/typecheck.c"
      , "src/builtins.c"
      , "src/serialize.c"
      , "src/import.c"
      , "src/bignum.c"
      , "src/sha256.c"
      , "src/ssrf.c"
      , "src/http.c"
      ]

let hdr = [ "src/dhall.h", "src/ssrf.h", "src/json.h" ]

-- sha256 of each core source, in the same order (verified-build integrity).
let coreHashes =
      [ { path = "src/arena.c"
        , hash = "sha256:d025633194ecae134ce25f47ed30d025cda3633ef7df749be8f812cac85a4b5e"
        }
      , { path = "src/lexer.c"
        , hash = "sha256:2eecc4703e64d2ee186ed3b65b87f973bbc3e5dc79bfc36096bd914bf33794ce"
        }
      , { path = "src/parser.c"
        , hash = "sha256:4c3bc73611a94df1dc9b15b28afa82403d18f9d876d29fcdb383fa6949b9c9f2"
        }
      , { path = "src/ast.c"
        , hash = "sha256:e7a4d62f2f26d612cbad6ca2d803c4b26d5ce35b12fe5ecb6033750833bd92d9"
        }
      , { path = "src/normalize.c"
        , hash = "sha256:323604b338f6e9f12a8a7552df38efd80574bfa8de15590d036efff699718ea2"
        }
      , { path = "src/typecheck.c"
        , hash = "sha256:f54567788bdd8ac65139926e3cef5e287e3882f02a35d95d2c4f2cac89d37c30"
        }
      , { path = "src/builtins.c"
        , hash = "sha256:bd8a279c18368f67fae78753dc7f7d0d8edba4651acaa34b960fcf05b42fc936"
        }
      , { path = "src/serialize.c"
        , hash = "sha256:1d47a1d828072c6c9284afe28410fa2ddde5dc18984583be620df8dcf27f20a9"
        }
      , { path = "src/import.c"
        , hash = "sha256:48d5014f36bac6bcbe836e612635b1954a963a7316658588c1eb4ed738b6858e"
        }
      , { path = "src/bignum.c"
        , hash = "sha256:01b43c3c980f88b80da7f26836458540c7fa611df5b5dc205f670aa5dc5188fd"
        }
      , { path = "src/sha256.c"
        , hash = "sha256:dfdd76023d85b821e735ecad9b0be3ef11129656feb018874461a00329ab279e"
        }
      , { path = "src/ssrf.c"
        , hash = "sha256:807c8acf89548b023df3393cc5f43ab31b0024c3b52c8482355b6162cff1cf81"
        }
      , { path = "src/http.c"
        , hash = "sha256:9dbbd36a61b2980bea214bb49eb64d19dae1ce6654685e3f77afccd3cbc453e3"
        }
      ]

-- sha256 of the shared headers.
let hdrHashes =
      [ { path = "src/dhall.h"
        , hash = "sha256:b1874785500777aa182e6bba791942660df8190253555a8017bc90d23a2107dc"
        }
      , { path = "src/ssrf.h"
        , hash = "sha256:5987d7ea8ce6ac1d6dfdcec1e199cd44ccb3235d537cd5724528867038451a3f"
        }
      , { path = "src/json.h"
        , hash = "sha256:0697fb1bde0c17749de18a9d59644a4c7adf438de96ed4733885e9bf2701ca4e"
        }
      ]

-- CFLAGS shared by every compile (matches the Makefile).
let flags = "-std=c11 -O2 -g -Wall -Wextra"

in  { targets =
        -- `all` and the default: build the interpreter (dhake.com-style entry).
        [ { mapKey = "all"
          , mapValue = { deps = [ "dhall.com" ], phony = True, recipe = [] : List Action }
          }
        , { mapKey = "dhall.com"
          , mapValue =
              { deps = [ "src/main.c" ] # core # hdr
              , phony = False
              -- expected sha256 of the produced dhall.com (deterministic APE)
              , hash = "sha256:ee331990813ab2abf98c83578561ff371ee78014fc8cb4d8cdfcf49ea1213511"
              -- expected sha256 of each source dep (verified before build)
              , depsHash =
                  [ { path = "src/main.c"
                    , hash = "sha256:82b4b2696fdbc7fac040fef3671b9cf6786e0397ebd378ecadb2dce3172a3f01"
                    }
                  ] # coreHashes # hdrHashes
              , recipe =
                  [ < Shell =
                        "cosmocc " ++ flags ++ " -o dhall.com src/main.c "
                      ++ "src/arena.c src/lexer.c src/parser.c src/ast.c "
                      ++ "src/normalize.c src/typecheck.c src/builtins.c "
                      ++ "src/serialize.c src/import.c src/bignum.c "
                      ++ "src/sha256.c src/ssrf.c src/http.c"
                    >
                  ]
              }
          }

        -- benchmark binary + a phony `bench` that builds then runs it.
        , { mapKey = "bench.com"
          , mapValue =
              { deps = [ "src/bench.c" ] # core # hdr
              , phony = False
              , hash = "sha256:b13e548a7708158d656a301603a11aa2e6a27ad239b7f224c618d835086e46f9"
              , depsHash =
                  [ { path = "src/bench.c"
                    , hash = "sha256:e2e0dda2c1b1f15b54bd0f709ea6ff35d106fe6c6654a393dbd6c6a854e040fd"
                    }
                  ] # coreHashes # hdrHashes
              , recipe =
                  [ < Shell =
                        "cosmocc " ++ flags ++ " -o bench.com src/bench.c "
                      ++ "src/arena.c src/lexer.c src/parser.c src/ast.c "
                      ++ "src/normalize.c src/typecheck.c src/builtins.c "
                      ++ "src/serialize.c src/import.c src/bignum.c "
                      ++ "src/sha256.c src/ssrf.c src/http.c"
                    >
                  ]
              }
          }
        , { mapKey = "bench"
          , mapValue =
              { deps = [ "bench.com" ], phony = True
              , recipe = [ < Shell = "./bench.com.dbg" > ]
              }
          }

        -- LSP server: interpreter core (no main.c) + json.c + lsp.c.
        , { mapKey = "dhall-lsp.com"
          , mapValue =
              { deps = [ "src/lsp.c", "src/json.c" ] # core # hdr
              , phony = False
              , hash = "sha256:bbeb5481bfc7a096a012838751fc980e545f7a4a5fdbb104c4528fec36a00aea"
              , depsHash =
                  [ { path = "src/lsp.c"
                    , hash = "sha256:f78ffdde45c890106a8fbaa8b37fb4db13cc179ff0651384238d6b67b073e68f"
                    }
                  , { path = "src/json.c"
                    , hash = "sha256:5c900a3f480c5a39ff9737b0f32aacf1c02d0efab11779bc9582c249bb723d40"
                    }
                  ] # coreHashes # hdrHashes
              , recipe =
                  [ < Shell =
                        "cosmocc " ++ flags ++ " -o dhall-lsp.com src/lsp.c src/json.c "
                      ++ "src/arena.c src/lexer.c src/parser.c src/ast.c "
                      ++ "src/normalize.c src/typecheck.c src/builtins.c "
                      ++ "src/serialize.c src/import.c src/bignum.c "
                      ++ "src/sha256.c src/ssrf.c src/http.c"
                    >
                  ]
              }
          }
        , { mapKey = "lsp"
          , mapValue =
              { deps = [ "dhall-lsp.com" ], phony = True, recipe = [] : List Action }
          }
        , { mapKey = "test-lsp"
          , mapValue =
              { deps = [ "dhall-lsp.com" ], phony = True
              , recipe = [ < Shell = "./tests/lsp.sh ./dhall-lsp.com.dbg" > ]
              }
          }

        -- Offline SSRF classifier unit test (security crux), network-free.
        , { mapKey = "test-ssrf"
          , mapValue =
              { deps = [ "tests/ssrf_test.c", "src/ssrf.c", "src/ssrf.h" ]
              , phony = True
              , recipe =
                  [ < Shell =
                        "cosmocc " ++ flags ++ " -I src -o /tmp/ssrf_test "
                      ++ "tests/ssrf_test.c src/ssrf.c"
                    >
                  , < Shell = "/tmp/ssrf_test" >
                  ]
              }
          }

        -- WebAssembly build (emscripten) for the GitHub Pages demo in docs/.
        , { mapKey = "wasm"
          , mapValue =
              { deps = []
              , phony = True
              , recipe =
                  [ < Shell = "./scripts/build-wasm.sh" >
                  , < Shell = "node tests/wasm-smoke.js" >
                  , < Shell = "node tests/lsp-wasm-smoke.js" >
                  ]
              }
          }

        -- Full test suite: build everything, then run all the harnesses.
        , { mapKey = "test"
          , mapValue =
              { deps = [ "all", "test-ssrf", "test-lsp" ]
              , phony = True
              , recipe =
                  [ < Shell =
                        "./tests/run.sh ./dhall.com.dbg "
                      ++ "&& ./tests/roundtrip.sh ./dhall.com.dbg "
                      ++ "&& ./tests/examples.sh ./dhall.com.dbg "
                      ++ "&& ./tests/cli.sh ./dhall.com.dbg"
                    >
                  ]
              }
          }

        , { mapKey = "clean"
          , mapValue =
              { deps = []
              , phony = True
              , recipe =
                  [ < Rm = "dhall.com" >
                  , < Rm = "dhall.com.dbg" >
                  , < Rm = "dhall.aarch64.elf" >
                  , < Rm = "bench.com" >
                  , < Rm = "bench.com.dbg" >
                  , < Rm = "bench.aarch64.elf" >
                  , < Rm = "dhall-lsp.com" >
                  , < Rm = "dhall-lsp.com.dbg" >
                  , < Rm = "dhall-lsp.aarch64.elf" >
                  , < Rm = "/tmp/ssrf_test" >
                  , < Rm = "/tmp/ssrf_test.dbg" >
                  ]
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
        -- explicitly with `dhake dist/index.html`. The C interpreter stays the
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
                  , "docs/dhall.wasm"
                  , "docs/dhall-lsp.js"
                  , "docs/dhall-lsp.wasm"
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
