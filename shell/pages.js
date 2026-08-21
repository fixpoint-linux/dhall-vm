// shell/pages.js — canonical page definitions for the dhall-c MFE site.
//
// Single source of truth for all routes, templates, slots, and output paths.
// Imported by both shell/shell.js (browser ESM) and scripts/ssg.mjs (Node ESM).
//
// CANONICAL ROUTE TABLE (5 dhall-c pages):
//   '/dhall-c'           → template 'dhallc-landing'
//   '/dhall-c/language'  → template 'dhallc-language'
//   '/dhall-c/cli'       → template 'dhallc-cli'
//   '/dhall-c/api'       → template 'dhallc-api'
//   '/dhall-c/playground' → template 'dhallc-playground'
//
// SLOT NAME == TEMPLATE NAME for all dhall-c pages.
// The landing page's `dir` is '' so its output is dist/index.html.
// All other content pages have dir == slug, output to dist/<slug>/index.html.
// The cross-nav home route '/' → 'fixpoint' is handled separately (the main
// site owns /shell/templates/fixpoint.html and the importmap key
// 'fixpoint-landing').

export const PAGES = [
  {
    slug: 'dhall-c',
    path: '/dhall-c',
    slot: 'dhallc-landing',
    template: 'dhallc-landing',
    dir: '',
    title: 'dhall-c — a Dhall subset in C, compiled to a portable APE and WebAssembly',
    type: 'content',
  },
  {
    slug: 'language',
    path: '/dhall-c/language',
    slot: 'dhallc-language',
    template: 'dhallc-language',
    dir: 'language',
    title: 'Language — dhall-c',
    type: 'content',
  },
  {
    slug: 'cli',
    path: '/dhall-c/cli',
    slot: 'dhallc-cli',
    template: 'dhallc-cli',
    dir: 'cli',
    title: 'CLI — dhall-c',
    type: 'content',
  },
  {
    slug: 'api',
    path: '/dhall-c/api',
    slot: 'dhallc-api',
    template: 'dhallc-api',
    dir: 'api',
    title: 'C API — dhall-c',
    type: 'content',
  },
  {
    slug: 'playground',
    path: '/dhall-c/playground',
    slot: 'dhallc-playground',
    template: 'dhallc-playground',
    dir: 'playground',
    title: 'Playground — dhall-c',
    type: 'content',
  },
];

// All content pages (Elm-rendered, including the playground — Elm renders the
// hero/sections; the <dhall-playground> custom element is empty in static HTML
// and boots client-side).
export const CONTENT_PAGES = PAGES;

// Just the dhall-c pages (all of them).
export const DHALLC_PAGES = PAGES;
