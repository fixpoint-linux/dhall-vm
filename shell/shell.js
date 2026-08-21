// shell/shell.js — @mfe/framework thin-shell entry for the dhall-c MFE site.
//
// Boots the dhall-c docs app with 6 routes:
//   '/'                → template 'fixpoint'        (cross-nav home, main site)
//   '/dhall-c'         → template 'dhallc-landing'
//   '/dhall-c/language' → template 'dhallc-language'
//   '/dhall-c/cli'     → template 'dhallc-cli'
//   '/dhall-c/api'     → template 'dhallc-api'
//   '/dhall-c/playground' → template 'dhallc-playground'
//
// Matching the main site means a data-mfe-route like '/dhall-c' or '/'
// resolves the same way on either page, so cross-site MFE nav links agree.
//
// The pages ship statically pre-rendered (see scripts/ssg.mjs): the #app root
// carries an `ssr` attribute, so createApp rehydrates the existing DOM in
// place instead of wiping it and re-fetching the template on first paint.
//
// Rehydrate only when the current pathname (trailing-slash-stripped) matches
// a pre-rendered dhall-c page (all of them, including playground — the Elm app
// renders hero/sections and the <dhall-playground> element boots client-side).

import { createApp } from '@mfe/framework';

const app = await createApp({
  root: document.getElementById('app'),
  routes: [
    { path: '/', template: 'fixpoint', name: 'home' },
    { path: '/dhall-c', template: 'dhallc-landing', name: 'dhallc-landing' },
    { path: '/dhall-c/language', template: 'dhallc-language', name: 'dhallc-language' },
    { path: '/dhall-c/cli', template: 'dhallc-cli', name: 'dhallc-cli' },
    { path: '/dhall-c/api', template: 'dhallc-api', name: 'dhallc-api' },
    { path: '/dhall-c/playground', template: 'dhallc-playground', name: 'dhallc-playground' },
  ],
  basePath: '/',
  // dhall-c's templates are served from /dhall-c/shell/templates
  // (the main site owns /shell/templates). Pin the baseURL here so both route
  // templates resolve under this site's shell regardless of the deep-link subpath.
  baseURL: '/dhall-c/shell/templates',
  // The SSG output pre-renders all content pages EXCEPT the playground. The
  // playground page ships client-booted: the <dhall-playground> custom element
  // builds its editor on connectedCallback, and SSR rehydration would create a
  // SECOND element (double editor). Rehydrate only the pre-rendered non-playground
  // routes; the playground route gets a fresh client render instead.
  ssr: (() => {
    const path = (window.location.pathname.replace(/\/+$/, '') || '/');
    return (path === '/dhall-c' || path.startsWith('/dhall-c/'))
      && path !== '/dhall-c/playground';
  })(),
});

// Expose the app handle so the shell/host can inspect or drive it later.
window.__dhallcApp = app;
