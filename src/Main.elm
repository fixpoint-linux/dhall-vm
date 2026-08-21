module Main exposing (main)

{-| The dhall-c docs site as a plain `Browser.element` app.

This module renders the entire dhall-c site — landing, language, CLI, C API and
playground pages — using the shared `Fixpoint.*` design package
(`vendor/design/src` is a source-directory in this application's `elm.json`).

The first child of each view is `Fixpoint.Style.stylesheet`, which emits the
full brand stylesheet as a single `<style>` node. Because each page is
pre-rendered under happy-dom by `scripts/ssg.mjs`, that `<style>` node is
carried into the static HTML — the styling ships with the page instead of
living in a committed stylesheet.

The playground page embeds a `<dhall-playground>` custom element (registered by
`shell/mfe/playground-element.js`) which boots the wasm interpreter + LSP
client-side; in the static pre-render that element is empty.

The page to render is selected from the `pathname` flag. There is no
client-side interactivity in Elm itself (the model is the page, the only
message is `NoOp`) — the interactive playground is handled by the custom
element.

-}

import Browser
import Fixpoint.Callout
import Fixpoint.Card
import Fixpoint.Checks
import Fixpoint.Code
import Fixpoint.Cta
import Fixpoint.Footer
import Fixpoint.Grid
import Fixpoint.Headline
import Fixpoint.Hero
import Fixpoint.Nav
import Fixpoint.Section
import Fixpoint.Style
import Html exposing (Html, a, b, code, div, em, h3, li, node, p, pre, span, strong, text, ul)
import Html.Attributes exposing (attribute, class, href)


main : Program Flags Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }


type alias Flags =
    { pathname : String }


{-| Which dhall-c page to render, derived from the `pathname` flag.
-}
type Page
    = Landing
    | Language
    | Cli
    | Api
    | Playground


type Msg
    = NoOp


type alias Model =
    Page


init : Flags -> ( Model, Cmd Msg )
init flags =
    ( parsePage (stripDhallcPrefix flags.pathname), Cmd.none )


update : Msg -> Model -> ( Model, Cmd Msg )
update _ model =
    ( model, Cmd.none )


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.none



-- HELPERS


{-| Strip a leading `/dhall-c` prefix and any surrounding slashes so the
result is the bare sub-page slug (e.g. `"/dhall-c/language/"` -> `"language"`,
`"/dhall-c/"` -> `""`). Falls back to `""` for `/`.
-}
stripDhallcPrefix : String -> String
stripDhallcPrefix raw =
    let
        withoutPrefix =
            if String.startsWith "/dhall-c" raw then
                String.dropLeft (String.length "/dhall-c") raw

            else if raw == "/" then
                ""

            else
                raw
    in
    withoutPrefix
        |> String.dropLeft (if String.startsWith "/" withoutPrefix then 1 else 0)
        |> (\s -> if String.endsWith "/" s then String.dropRight 1 s else s)


parsePage : String -> Page
parsePage path =
    case path of
        "" ->
            Landing

        "language" ->
            Language

        "cli" ->
            Cli

        "api" ->
            Api

        "playground" ->
            Playground

        _ ->
            Landing



-- VIEW


view : Model -> Html Msg
view model =
    div []
        [ Fixpoint.Style.stylesheet
        , navView
        , pageView model
        , footerView
        ]


navView : Html Msg
navView =
    Fixpoint.Nav.view
        { brand = span [ class "fx" ] [ text "fx://dhall-c" ]
        , links =
            [ Fixpoint.Nav.homeLink "https://fixpointlinux.org/" "fixpoint-linux"
            , Fixpoint.Nav.link "/dhall-c" "Overview"
            , Fixpoint.Nav.link "/dhall-c/language" "Language"
            , Fixpoint.Nav.link "/dhall-c/cli" "CLI"
            , Fixpoint.Nav.link "/dhall-c/api" "C API"
            ]
        , extra =
            [ a [ class "home", href "/dhall-c/playground", attribute "data-mfe-route" "/dhall-c/playground" ]
                [ text "Playground →" ]
            ]
        }


pageView : Page -> Html Msg
pageView page =
    case page of
        Landing ->
            landingView

        Language ->
            languageView

        Cli ->
            cliView

        Api ->
            apiView

        Playground ->
            playgroundView


landingView : Html Msg
landingView =
    div []
        [ Fixpoint.Hero.view
            { prompt =
                [ Fixpoint.Hero.dollar
                , text " "
                , Fixpoint.Code.g "dhall-c"
                , text " — one C source, two targets"
                , Fixpoint.Hero.blink
                ]
            , title =
                [ text "A Dhall subset, "
                , Fixpoint.Hero.fx [ text "written in C" ]
                ]
            , tagline =
                [ text "Typecheck, normalize, and serialize Dhall configuration. The "
                , Fixpoint.Code.inline "same C interpreter"
                , text " ships two ways: a single "
                , Fixpoint.Code.inline "native binary"
                , text " that runs on every major OS, and a "
                , Fixpoint.Code.inline "WebAssembly"
                , text " build that runs right here in your browser."
                ]
            }
        , Fixpoint.Section.view
            { id = "targets"
            , title = "Compiled once for C. Delivered two ways."
            , hint = "// one source · two targets"
            , children =
                [ p []
                    [ text "The same lexer, parser, normalizer, and typechecker ("
                    , Fixpoint.Code.inline "src/*.c"
                    , text ") build into two artifacts that cover the entire spectrum — from your terminal to a browser tab."
                    ]
                , Fixpoint.Code.block
                    [ Fixpoint.Code.g "src/*.c"
                    , text "  — the interpreter · lexer · parser · normalize · typecheck · serialize · import\n"
                    , text "├─ "
                    , Fixpoint.Code.c "src/main.c"
                    , text "  → cosmocc    → "
                    , Fixpoint.Code.g "dhall.com"
                    , text "   one binary, many OSes\n"
                    , text "└─ "
                    , Fixpoint.Code.c "src/wasm.c"
                    , text "  → emscripten → "
                    , Fixpoint.Code.g "dhall.wasm"
                    , text "  zero-install, in your browser"
                    ]
                , Fixpoint.Grid.grid
                    [ Fixpoint.Card.view
                        { n = "01"
                        , title = "Native binary — dhall.com"
                        , body =
                            [ text "A single self-contained "
                            , strong [] [ text "~1 MB" ]
                            , text " Actually Portable Executable built with "
                            , Fixpoint.Code.inline "cosmocc"
                            , text ". The same file runs natively on Linux, macOS, Windows, and the BSDs — no VM, no runtime, no recompile."
                            ]
                        }
                    , Fixpoint.Card.view
                        { n = "02"
                        , title = "In the browser — dhall.wasm"
                        , body =
                            [ text "The same interpreter compiled to a "
                            , strong [] [ text "122 KB" ]
                            , text " "
                            , Fixpoint.Code.inline ".wasm"
                            , text " module. It runs "
                            , strong [] [ text "100% client-side"
                            , text " — no server, no upload."
                            ]
                            ]
                        }
                    ]
                , Fixpoint.Cta.view
                    { body =
                        [ strong [] [ text "Try it live." ]
                        , text " The playground runs the real interpreter (and the real LSP) in your browser."
                        ]
                    , href = "/dhall-c/playground"
                    , label = "Open the Playground →"
                    , attrs = [ attribute "data-mfe-route" "/dhall-c/playground" ]
                    }
                ]
            }
        , Fixpoint.Section.view
            { id = "features"
            , title = "A capable Dhall subset"
            , hint = "// single-term de Bruijn core, eager normalization, bidirectional typechecking"
            , children =
                [ Fixpoint.Headline.view
                    [ Fixpoint.Headline.card
                        { n = "typecheck"
                        , title = [ text "Bidirectional inference" ]
                        , body = [ p [] [ text "Precise " , Fixpoint.Code.inline "Error: … at line N, col M", text " diagnostics." ] ]
                        }
                    , Fixpoint.Headline.card
                        { n = "normalize"
                        , title = [ text "Eager, step-sound" ]
                        , body = [ p [] [ text "Normal forms re-parse and round-trip." ] ]
                        }
                    , Fixpoint.Headline.card
                        { n = "arbitrary precision"
                        , title = [ text "Big naturals & integers" ]
                        , body = [ p [] [ text "Unbounded " , Fixpoint.Code.inline "Natural", text " and ", Fixpoint.Code.inline "Integer", text " — no overflow, ", Fixpoint.Code.inline "Natural", text " subtraction saturates at 0." ] ]
                        }
                    , Fixpoint.Headline.card
                        { n = "imports"
                        , title = [ text "File, env, and http" ]
                        , body = [ p [] [ text "Local file imports, ", Fixpoint.Code.inline "env:", text " imports, and ", Fixpoint.Code.inline "http://", text " URLs with mandatory ", Fixpoint.Code.inline "sha256:", text " hashes and ", Fixpoint.Code.inline "?", text " fallback." ] ]
                        }
                    , Fixpoint.Headline.card
                        { n = "serializers"
                        , title = [ text "JSON · TOML · YAML" ]
                        , body = [ p [] [ text "One evaluated value tree renders to all three from the same shared representation." ] ]
                        }
                    , Fixpoint.Headline.card
                        { n = "records & unions"
                        , title = [ text "merge, toMap, with" ]
                        , body = [ p [] [ text "Recursive ", Fixpoint.Code.inline "/\\", text " merge, right-biased ", Fixpoint.Code.inline "//", text ", ", Fixpoint.Code.inline "with", text " updates, and the empty record." ] ]
                        }
                    , Fixpoint.Headline.card
                        { n = "assert"
                        , title = [ text "Type-level checks" ]
                        , body = [ p [] [ text "Enforced in every mode — typecheck, normalize, and all three serializers." ] ]
                        }
                    , Fixpoint.Headline.card
                        { n = "unicode"
                        , title = [ text "Unicode operators" ]
                        , body = [ p [] [ text "λ → ∀ ∧ ⫽ ≡ accepted alongside their ASCII spellings." ] ]
                        }
                    ]
                ]
            }
        ]


languageView : Html Msg
languageView =
    div []
        [ Fixpoint.Hero.view
            { prompt = [ Fixpoint.Hero.dollar, text " dhall-c/language", Fixpoint.Hero.blink ]
            , title = [ text "The Dhall subset" ]
            , tagline = [ text "What the interpreter accepts and how it evaluates it." ]
            }
        , Fixpoint.Section.view
            { id = "values"
            , title = "Values"
            , hint = "// scalars · records · lists · unions · optionals"
            , children =
                [ Fixpoint.Checks.view
                    [ li [] [ text "Scalars — " , Fixpoint.Code.inline "Natural", text ", ", Fixpoint.Code.inline "Integer", text ", ", Fixpoint.Code.inline "Double", text ", ", Fixpoint.Code.inline "Bool", text ", ", Fixpoint.Code.inline "Text", text " (with ", Fixpoint.Code.inline "${}", text " interpolation)." ]
                    , li [] [ text "Records — record types ", Fixpoint.Code.inline "{ a : T }", text ", literals ", Fixpoint.Code.inline "{ a = v }", text ", field access, ", Fixpoint.Code.inline "toMap", text ", recursive merge ", Fixpoint.Code.inline "/\\", text ", right-biased ", Fixpoint.Code.inline "//", text ", and ", Fixpoint.Code.inline "with", text " updates." ]
                    , li [] [ text "Lists — ", Fixpoint.Code.inline "[a, b, c]", text ", list append ", Fixpoint.Code.inline "#", text ", and ", Fixpoint.Code.inline "List/map", text ", ", Fixpoint.Code.inline "filter", text ", ", Fixpoint.Code.inline "fold", text ", ", Fixpoint.Code.inline "build", text ", ", Fixpoint.Code.inline "length", text ", ", Fixpoint.Code.inline "head", text ", ", Fixpoint.Code.inline "last", text ", ", Fixpoint.Code.inline "indexed", text ", ", Fixpoint.Code.inline "reverse", text "." ]
                    , li [] [ text "Unions — ", Fixpoint.Code.inline "< A : T | B : U >", text " and ", Fixpoint.Code.inline "< A = v | B : U >", text ", plus ", Fixpoint.Code.inline "merge", text "." ]
                    , li [] [ text "Optionals — ", Fixpoint.Code.inline "Optional T", text ", ", Fixpoint.Code.inline "Some x", text ", ", Fixpoint.Code.inline "None T", text ", ", Fixpoint.Code.inline "Optional/fold", text "." ]
                    ]
                ]
            }
        , Fixpoint.Section.view
            { id = "binders"
            , title = "Binders & control"
            , hint = "// let · lambda · forall · if/then/else"
            , children =
                [ Fixpoint.Checks.view
                    [ li [] [ text "let bindings and chained lets." ]
                    , li [] [ text "Lambdas ", Fixpoint.Code.inline "\\(x : T) -> body", text " and ", Fixpoint.Code.inline "forall", text "/Pi types." ]
                    , li [] [ text "Annotations ", Fixpoint.Code.inline "e : T", text " and ", Fixpoint.Code.inline "if/then/else", text "." ]
                    , li [] [ text "Multiline ", Fixpoint.Code.inline "Text", text " literals (", Fixpoint.Code.inline "'' … ''", text ") with standard indentation stripping." ]
                    ]
                ]
            }
        , Fixpoint.Section.view
            { id = "builtins"
            , title = "Builtins"
            , hint = "// arithmetic · comparison · natural/integer/double/text ops"
            , children =
                [ p []
                    [ text "Arithmetic "
                    , Fixpoint.Code.inline "+ - *"
                    , text " over "
                    , Fixpoint.Code.inline "Natural"
                    , text "/"
                    , Fixpoint.Code.inline "Integer"
                    , text "/"
                    , Fixpoint.Code.inline "Double"
                    , text ", boolean logic "
                    , Fixpoint.Code.inline "&&"
                    , text " "
                    , Fixpoint.Code.inline "||"
                    , text ", and comparisons "
                    , Fixpoint.Code.inline "== != < <= > >="
                    , text ". Plus "
                    , Fixpoint.Code.inline "Natural/build"
                    , text ", "
                    , Fixpoint.Code.inline "Natural/isZero"
                    , text ", "
                    , Fixpoint.Code.inline "Integer/toDouble"
                    , text ", "
                    , Fixpoint.Code.inline "Text/replace"
                    , text ", "
                    , Fixpoint.Code.inline "Double/show"
                    , text ", and more."
                    ]
                , Fixpoint.Callout.note
                    [ text "Round-trip Doubles: IEEE 754 "
                    , Fixpoint.Code.inline "Double"
                    , text " printed with the shortest representation that round-trips; non-finite maps to "
                    , Fixpoint.Code.inline "null"
                    , text "/"
                    , Fixpoint.Code.inline "nan"
                    , text "/"
                    , Fixpoint.Code.inline "inf"
                    , text "."
                    ]
                ]
            }
        ]


cliView : Html Msg
cliView =
    div []
        [ Fixpoint.Hero.view
            { prompt = [ Fixpoint.Hero.dollar, text " dhall-c/cli", Fixpoint.Hero.blink ]
            , title = [ text "The dhall CLI" ]
            , tagline = [ text "A single APE binary with five evaluation modes." ]
            }
        , Fixpoint.Section.view
            { id = "usage"
            , title = "Usage"
            , hint = "// dhall <mode> [file|-]"
            , children =
                [ Fixpoint.Code.block
                    [ Fixpoint.Code.g "dhall typecheck"
                    , text " [file|-]   # infer the type of an expression\n"
                    , Fixpoint.Code.g "dhall normalize"
                    , text " [file|-]   # print the normal form\n"
                    , Fixpoint.Code.g "dhall to-json"
                    , text "   [file|-]   # evaluate to JSON\n"
                    , Fixpoint.Code.g "dhall to-toml"
                    , text "   [file|-]   # evaluate to TOML (top level must be a record)\n"
                    , Fixpoint.Code.g "dhall to-yaml"
                    , text "   [file|-]   # evaluate to YAML (block style, 1.2 core schema)\n"
                    , Fixpoint.Code.g "dhall --help"
                    , text " | "
                    , Fixpoint.Code.g "-h"
                    , text "          # print usage and exit 0\n"
                    , Fixpoint.Code.g "dhall --version"
                    , text " | "
                    , Fixpoint.Code.g "-V"
                    , text "       # print the version and exit 0"
                    ]
                , p []
                    [ text "Input is read from a file or stdin. Exit codes: "
                    , Fixpoint.Code.inline "0"
                    , text " ok, "
                    , Fixpoint.Code.inline "1"
                    , text " type error, "
                    , Fixpoint.Code.inline "2"
                    , text " parse/lex error, "
                    , Fixpoint.Code.inline "3"
                    , text " internal/IO/serialize error. Type errors report "
                    , Fixpoint.Code.inline "Error: <msg> (at <file>:<line>:<col>)"
                    , text "."
                    ]
                , Fixpoint.Callout.warn
                    [ text "Imports: local file "
                    , Fixpoint.Code.inline "./file"
                    , text ", "
                    , Fixpoint.Code.inline "env:NAME"
                    , text ", and "
                    , Fixpoint.Code.inline "http://"
                    , text " URLs. URL imports are SSRF-safe and require a mandatory "
                    , Fixpoint.Code.inline "sha256:"
                    , text " hash."
                    ]
                ]
            }
        , Fixpoint.Section.view
            { id = "build"
            , title = "Build"
            , hint = "// driven by dhake"
            , children =
                [ Fixpoint.Code.block
                    [ Fixpoint.Code.c "# build the native APE + run the full suite"
                    , text "\n"
                    , Fixpoint.Code.k "$"
                    , text " "
                    , Fixpoint.Code.g "dhake"
                    , text "\n"
                    , Fixpoint.Code.k "$"
                    , text " "
                    , Fixpoint.Code.g "dhake test"
                    , text "    # run.sh + roundtrip.sh + examples.sh + cli.sh\n"
                    , Fixpoint.Code.k "$"
                    , text " "
                    , Fixpoint.Code.g "dhake bench"
                    , text "   # in-process benchmark"
                    ]
                , p []
                    [ text "Requires "
                    , Fixpoint.Code.inline "cosmocc"
                    , text " (Cosmopolitan toolchain) and the "
                    , Fixpoint.Code.inline "dhake"
                    , text " binary. Every compile target pins verified-build sha256 hashes for its source deps and output."
                    ]
                ]
            }
        ]


apiView : Html Msg
apiView =
    div []
        [ Fixpoint.Hero.view
            { prompt = [ Fixpoint.Hero.dollar, text " dhall-c/api", Fixpoint.Hero.blink ]
            , title = [ text "The C API" ]
            , tagline = [ text "The interpreter core as a callable C library." ]
            }
        , Fixpoint.Section.view
            { id = "api"
            , title = "API surface"
            , hint = "// src/dhall.h"
            , children =
                [ p []
                    [ text "The interpreter exposes a clean C API over the de Bruijn core: "
                    , Fixpoint.Code.inline "parse_source"
                    , text " (lex+parse), "
                    , Fixpoint.Code.inline "infer_type"
                    , text " (bidirectional typecheck), "
                    , Fixpoint.Code.inline "normalize"
                    , text " (eager, step-sound), and the "
                    , Fixpoint.Code.inline "serialize.c"
                    , text " writers (JSON/TOML/YAML). All allocation flows through the "
                    , Fixpoint.Code.inline "arena"
                    , text "."
                    ]
                , Fixpoint.Code.block
                    [ Fixpoint.Code.k "#include"
                    , text " "
                    , Fixpoint.Code.g "dhall.h"
                    , text "\n\n"
                    , Fixpoint.Code.c "// parse + typecheck + normalize a source string"
                    , text "\n"
                    , Fixpoint.Code.k "DhallError"
                    , text " "
                    , Fixpoint.Code.g "err"
                    , text ";\n"
                    , Fixpoint.Code.k "Term"
                    , text " "
                    , Fixpoint.Code.g "t"
                    , text " = "
                    , Fixpoint.Code.g "parse_source"
                    , text "(src, "
                    , Fixpoint.Code.g "&err"
                    , text ");\n"
                    , Fixpoint.Code.k "Term"
                    , text " "
                    , Fixpoint.Code.g "ty"
                    , text " = "
                    , Fixpoint.Code.g "infer_type"
                    , text "(t, "
                    , Fixpoint.Code.g "&err"
                    , text ");\n"
                    , Fixpoint.Code.k "Term"
                    , text " "
                    , Fixpoint.Code.g "nf"
                    , text " = "
                    , Fixpoint.Code.g "normalize"
                    , text "(t);"
                    ]
                , p []
                    [ text "The same core, compiled to wasm, is what powers the "
                    , Fixpoint.Code.inline "<dhall-playground>"
                    , text " in your browser (via "
                    , Fixpoint.Code.inline "src/wasm.c"
                    , text " and the LSP in "
                    , Fixpoint.Code.inline "src/lsp.c"
                    , text ")."
                    ]
                ]
            }
        , Fixpoint.Section.view
            { id = "lsp"
            , title = "Language server"
            , hint = "// dhall-lsp.com · JSON-RPC 2.0 over stdio"
            , children =
                [ p []
                    [ text "A Language Server Protocol server gives editors live diagnostics and hover types, reusing the interpreter core for everything it reports. "
                    , Fixpoint.Code.inline "dhake dhall-lsp.com"
                    , text " builds it; "
                    , Fixpoint.Code.inline "dhake test-lsp"
                    , text " runs the end-to-end checks."
                    ]
                ]
            }
        ]


playgroundView : Html Msg
playgroundView =
    div []
        [ Fixpoint.Hero.view
            { prompt = [ Fixpoint.Hero.dollar, text " dhall-c/playground", Fixpoint.Hero.blink ]
            , title = [ text "Playground" ]
            , tagline = [ text "The real interpreter and LSP, compiled to WebAssembly, running in this tab." ]
            }
        , Fixpoint.Section.view
            { id = "playground"
            , title = "Live demo"
            , hint = "// typecheck · normalize · to-json · to-toml · to-yaml · live LSP"
            , children =
                [ p []
                    [ text "Pick a mode, edit the source, then press "
                    , Fixpoint.Code.inline "Run"
                    , text " or "
                    , Fixpoint.Code.inline "Ctrl/⌘+Enter"
                    , text ". The editor is a real "
                    , Fixpoint.Code.inline "CodeMirror"
                    , text " with Dhall syntax highlighting, and the actual "
                    , Fixpoint.Code.inline "dhall-lsp"
                    , text " server (the same "
                    , Fixpoint.Code.inline "src/lsp.c"
                    , text ", compiled to wasm) runs behind it — live squiggles as you type, and hover shows the inferred type."
                    ]
                , node "dhall-playground" [] []
                ]
            }
        ]


footerView : Html Msg
footerView =
    Fixpoint.Footer.view
        [ text "dhall-c — a pure-C11 subset of the "
        , a [ href "https://dhall-lang.org/" ] [ text "Dhall" ]
        , text " configuration language"
        , Fixpoint.Footer.sep
        , a [ href "https://github.com/fixpoint-linux/dhall-c" ] [ text "github" ]
        , Fixpoint.Footer.sep
        , text "built with "
        , Fixpoint.Code.inline "cosmocc"
        , text " · runs in your browser via "
        , Fixpoint.Code.inline "emscripten"
        ]
