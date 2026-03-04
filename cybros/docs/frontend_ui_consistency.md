# Frontend UI consistency rules (Tailwind v4 + daisyUI v5)

This document is a **ruleset + checklist** for keeping Cybros UI consistent while iterating quickly.

## DO NOT TOUCH (short list)

These are the frozen “bones” of the app. Feature pages can evolve, but these rules must stay stable.

- Keep the **single** global toast stack: `#toast_container` (do not create per-page toasts).
- Keep shells frozen: `layouts/application`, `layouts/agent`, `layouts/settings`, `layouts/session`, `layouts/landing`.
- Keep the shared navbar contract: `sticky top-0 z-40 h-14 ... bg-base-100 border-base-300`.
- Agent layout remains a **3-pane drawer mold**; right drawer exists **only** when `content_for?(:right_sidebar)` exists.
- Keep left sidebar width contract: closed `w-16`, open `w-80` (with `max-w-[85vw]`).
- Keep agent header canonical: use `layouts/agent/_header.html.erb` (don’t duplicate header markup in pages).
- No custom z-index tiers and no `z-[...]` values.
- No inline JS (`onclick=...` etc). Dialogs must use Stimulus `dialog_controller`.
- No HTML string concatenation in JS for repeated UI; use `<template>` + `cloneNode`.
- Always treat Turbo Stream HTTP responses as UI truth; ActionCable is best-effort.

## Hard gates (PR checklist)

Any UI/Stimulus/JS change must satisfy all items below.

- **Layout shells stay frozen**: do not restructure `layouts/application`, `layouts/agent`, `layouts/settings`, `layouts/session`, `layouts/landing`. Only fill slots.
- **No duplicate header shells**: agent header must be `layouts/agent/_header.html.erb`.
- **Right sidebar is truly optional**: do not render the right drawer/toggle unless `content_for?(:right_sidebar)` exists.
- **z-index must stay native**: only use `z-0/10/20/30/40/50`. Never use `z-[...]` or new tiers.
- **No inline JS in views**: never add `onclick=...` or inline scripts for UI interactions.
- **Dialogs use Stimulus**: `<dialog>` must be opened/closed via `dialog_controller` (`click->dialog#open/close`).
- **No HTML string building in JS** for repeated UI: use `<template>` + `cloneNode`.
- **XSS safety**: user-controlled content must be inserted via `textContent`, not `innerHTML`.
- **Toasts are global-only**: dispatch `toast:show` and render into the single `#toast_container`.
- **Templates are shared**: reusable templates live in `app/views/_shared/_js_templates.html.erb`, rendered once by the application shell.
- **Turbo Streams are truth**: state-changing actions must converge via HTTP Turbo Stream responses; ActionCable is best-effort.
- **Non-2xx Turbo Streams still render** when fetched via JS (errors must be visible in UI).
- **Race-condition safety**: do not rely on controller instance fields for processing locks; Turbo replace re-inits controllers.
- **Multi-source updates need a revision**: if multiple sources can update the same target, add a monotonic revision and ignore stale updates.
- **Surface tokens are standardized**: cards/panels must use approved recipes (`bg/base`, `border-base-300`, `shadow-sm`; overlays `shadow-lg`).
- **Semantic colors only**: use `base-*` + daisyUI semantic colors; avoid raw palette colors unless debug-only.
- **No custom CSS unless unavoidable**: prefer daisyUI + Tailwind utilities; if custom CSS is added, document the reason.

## What “consistent” means (style fingerprint)

The Cybros UI style fingerprint should feel like:

- **Soft-neutral surfaces**: mostly `base-*` backgrounds with subtle borders; primary color reserved for actions.
- **Low-noise hierarchy**: a small set of opacities for secondary/tertiary text and consistent typography scale.
- **Small set of tokens**: z-index, spacing, radius, shadows, and icon sizes use a fixed shortlist (no ad-hoc numbers).
- **daisyUI-first components**: most UI is built from daisyUI primitives with light Tailwind layout composition.

## Core principles

- **Prefer daisyUI components first** (`btn`, `card`, `menu`, `navbar`, `tabs`, `alert`, `toast`, `drawer`, etc).
- **Use Tailwind utilities to compose layouts**, not to invent a second design system.
- **Avoid custom CSS** unless (a) a daisyUI component can’t do it, and (b) a Tailwind-only solution is awkward or would duplicate a lot of classes.
- **Use semantic colors** (`base-*`, `primary`, `secondary`, `accent`, `info/success/warning/error`) so themes work automatically.
- **If a UI pattern appears 2+ times**, extract to a partial under `app/views/_shared/` or `app/views/layouts/**`.

## Layout contracts (frozen)

Phase 0–0.5 UI treats **layouts as product infrastructure**. Feature pages may be redesigned, but **the layout shells below are frozen** unless we explicitly decide to do a layout migration.

This is the contract: pages can fill **slots** and compose **partials**, but should not change the skeleton DOM structure or the token choices baked into the shell.

### Immutable class map (do not change)

These are the “layout infrastructure” classes. Treat them as **API**.

If you need to change one of these:

- Update this document
- Update all usages consistently
- Re-verify layout parity and run tests

#### Global toast stack

- Element: `#toast_container`
- Must remain a daisyUI toast stack and top-right positioned:
  - `toast toast-top toast-end`
  - Overlay layer: `z-50`

#### Shared navbar

- Element: `layouts/_navbar.html.erb` root `<header>`
- Must remain:
  - `navbar sticky top-0 z-40 h-14`
  - Horizontal padding: `px-4 md:px-8`
  - Surface: `border-b bg-base-100 border-base-300`

#### Agent layout: outer left drawer

- Element: `layouts/agent.html.erb` outer `.drawer`
- Must remain:
  - `drawer lg:drawer-open h-dvh`
  - `data-controller="sidebar" data-sidebar-key-value="left"`
  - Left drawer toggle id: `left_drawer`

#### Agent layout: left sidebar container

- Element: left `<aside>` inside left `drawer-side`
- Must preserve width contract and transitions:
  - `is-drawer-close:w-16 is-drawer-open:w-80 max-w-[85vw]`
  - `transition-[width] duration-200`
  - Surface: `bg-base-100 border-r border-base-300`
  - Overflow: `overflow-visible` (prevents tooltip clipping in collapsed state)

#### Agent layout: optional right drawer

- Render only when `content_for?(:right_sidebar)` is set.
- Must remain:
  - `drawer drawer-end h-full`
  - `data-controller="sidebar" data-sidebar-key-value="right"`
  - Right drawer toggle id: `right_drawer`
- Right sidebar `<aside>` width contract must remain:
  - `w-96 max-w-[85vw]`
  - Surface: `bg-base-100 border-l border-base-300`

#### Agent header

- Element: `layouts/agent/_header.html.erb` root `<header>`
- Must remain:
  - `navbar h-14 px-4`
  - Surface: `bg-base-100 border-b border-base-300`
- Right sidebar toggle:
  - Must only render when the right drawer exists

#### Settings layout container

- Element: `layouts/settings.html.erb` main container
- Must remain:
  - `max-w-7xl mx-auto`
  - `px-4 md:px-6 lg:px-8`
  - `py-6 md:py-8`

### Global application shell (`app/views/layouts/application.html.erb`)

Frozen invariants:

- The root HTML shell must:
  - Render `layouts/shared/_head`
  - Render `yield(:content)` (or `yield`) for page content
  - Render `_shared/_js_templates` once
  - Contain a **single global toast stack container** with id `toast_container`
- Flash messages must render **inside** the toast container (not in-page), so that login/logout and general flash UX stays consistent across all layouts.

Slots:

- `content_for(:layout_name)` sets `data-layout` for debugging and future per-layout policies.
- `content_for(:body_class)` for page-level body sizing (e.g. `h-dvh overflow-hidden` in agent layout).

### Shared navbar (`app/views/layouts/_navbar.html.erb`)

Frozen invariants:

- Height is fixed: `h-14`
- Sticky layering is fixed: `sticky top-0 z-40`
- Surface recipe is fixed: `border-b bg-base-100 border-base-300`
- No per-page navbar styling variants (blur/transparency) unless adopted globally.

### Agent layout (three-pane shell) (`app/views/layouts/agent.html.erb`)

This is the primary “application layout”. It is a **drawer-based 3-pane mold**.

Frozen invariants:

- Outer left drawer container is always present and uses `data-controller="sidebar" data-sidebar-key-value="left"`.
- The left sidebar width contract must not change:
  - Closed: `is-drawer-close:w-16`
  - Open: `is-drawer-open:w-80` (with `max-w-[85vw]`)
- The right drawer is **conditional**:
  - Only render the right drawer and its toggle when `content_for?(:right_sidebar)` is present.
  - When present, it uses `data-controller="sidebar" data-sidebar-key-value="right"`.
- Header must be rendered via the shared partial:
  - `app/views/layouts/agent/_header.html.erb` is the canonical header markup.
- Main content must remain `min-h-0 overflow-hidden` friendly (so chat scrolling is correct).

Slots:

- `content_for(:left_sidebar)` optional override; default renders `layouts/agent/sidebar`
- `content_for(:right_sidebar)` optional
- `content_for(:action_bar)` optional (header start area)

### Agent header (`app/views/layouts/agent/_header.html.erb`)

Frozen invariants:

- Height fixed: `h-14`
- Surface recipe fixed: `bg-base-100 border-b border-base-300`
- Right sidebar toggle button exists **only** when right sidebar is present.

### Agent sidebar (`app/views/layouts/agent/_sidebar.html.erb`)

Frozen invariants:

- Theme toggle + account menu live **at the bottom** of the left sidebar.
- Primary nav and conversation sections stay as separate partials to avoid drift:
  - `layouts/agent/_sidebar_primary_nav.html.erb`
  - `layouts/agent/_sidebar_conversations_section.html.erb`

### Settings layout (`app/views/layouts/settings.html.erb`)

Frozen invariants:

- Uses the shared navbar.
- Page container width and padding are fixed:
  - `max-w-7xl mx-auto`
  - `px-4 md:px-6 lg:px-8`
  - `py-6 md:py-8`
- Sidebar nav structure is stable (tabs on mobile, menu on desktop).

### Session + Landing layouts (`app/views/layouts/session.html.erb`, `app/views/layouts/landing.html.erb`)

Frozen invariants:

- Session pages are intentionally minimal and should not reintroduce their own navbar/toast stacks.
- Landing uses the shared navbar and a simple `min-h-dvh flex flex-col` structure.

### Slot usage examples (preferred patterns)

Pages should only “plug in” content via slots; do not restructure the shells.

#### Agent layout: typical page

- `content_for(:action_bar)`: small header label/breadcrumb/title
- `content_for(:left_sidebar)`: optional override (rare; default should be used)
- `content_for(:right_sidebar)`: optional; when present enables right drawer + settings button

Example shape:

```erb
<% content_for :action_bar do %>
  <div class="flex items-center gap-2 min-w-0">
    <div class="truncate text-sm font-semibold">Page title</div>
  </div>
<% end %>

<% content_for :right_sidebar do %>
  <div class="p-4 space-y-4">
    <!-- settings/panel content -->
  </div>
<% end %>
```

#### Settings layout: page content only

Settings views should render only the inner page content (no wrapper layout inside views).

Example shape:

```erb
<div class="space-y-6">
  <div>
    <h2 class="text-lg font-semibold">Section</h2>
    <p class="text-sm opacity-70">Description</p>
  </div>

  <div class="card bg-base-200/30 border border-base-300 shadow-sm">
    <div class="card-body">
      <!-- form/table -->
    </div>
  </div>
</div>
```

### Layout change process (when you really must)

Because shells are frozen, layout changes must be treated as migrations:

- Update this document first (what is changing, why, and new invariants).
- Change the layout and all dependent partials in one PR/commit series.
- Rebuild assets + run tests.
- Manually verify the core pages (landing, login/setup, dashboard, settings, conversations).

## Best practices for views + JS (must-follow)

**Exception**: “SillyTavern message layout” is not applicable to Cybros and must not be reintroduced as-is.

### 1) HTML template mode (no HTML-string building)

Problem with JS HTML-string building:

- Low maintainability (HTML mixed into logic)
- No Rails i18n support for embedded strings (`t(...)`)
- Copy/pasted escaping helpers across controllers
- Style drift (different toasts/menus end up with different classes)

Rule:

- Do not build repeated UI by string concatenation in JS.
- Define reusable DOM templates in one shared view partial:
  - `app/views/_shared/_js_templates.html.erb`
- JS only clones and fills.

Template example:

```erb
<template id="toast_template">
  <div class="alert shadow-lg">
    <span data-toast-message></span>
  </div>
</template>
```

JS usage (XSS-safe):

```javascript
const template = document.getElementById("toast_template")
if (!template) return

const toast = template.content.cloneNode(true).firstElementChild
if (!toast) return

toast.querySelector("[data-toast-message]").textContent = message
container.appendChild(toast)
```

When to use template mode:

- ✅ Repeated simple UI elements (toast, chips/badges, list items)
- ⚠️ Complex dynamic forms: prefer Turbo Frames or server rendering
- ❌ If server already returns HTML, use the returned HTML (don’t rebuild it)

### 2) Toast standardization (global event only)

All toasts must be triggered via a single global event, never “local toast DOM”.

Event shape:

- `message`: string (required)
- `type`: `info | success | warning | error` (default `info`)
- `duration`: number ms (default `5000`)

Dispatch:

```javascript
window.dispatchEvent(
  new CustomEvent("toast:show", {
    detail: { message, type: "info", duration: 5000 },
    bubbles: true,
    cancelable: true,
  }),
)
```

Handler responsibilities (global, in app entrypoint):

- Get `#toast_template`
- Clone/fill with `textContent`
- Append to `#toast_container`
- Let the toast Stimulus controller handle animation + auto-dismiss

### 3) XSS safety (default to `textContent`)

- Prefer `textContent` over `innerHTML` whenever content can include user input.
- `innerHTML` is allowed only for strictly controlled content (e.g. trusted server-rendered HTML).
- If you must generate HTML in JS (rare), escape first.

### 4) Stimulus controller conventions

Targets naming: semantic and stable.

```javascript
static targets = ["content", "textarea", "submitBtn"]
```

Use values for declarative state:

```javascript
static values = {
  messageId: Number,
  editing: { type: Boolean, default: false },
  url: String,
}
```

Events:

- Prefer Stimulus events for local coordination:

```javascript
this.dispatch("updated", { detail: { id: this.idValue } })
```

- Use global events only for truly global concerns (e.g. `toast:show`).

### 5) Dialog/Modal conventions (no inline JS)

- Use `<dialog>` + Stimulus `dialog_controller` (`click->dialog#open`, `click->dialog#close`).
- Never use inline handlers (`onclick="..."`).

Example shape:

```erb
<button type="button"
        data-controller="dialog"
        data-dialog-id-value="import_modal"
        data-action="click->dialog#open">
  Import
</button>

<dialog id="import_modal" class="modal">
  <div class="modal-box">
    ...
    <button type="button" class="btn"
            data-controller="dialog"
            data-action="click->dialog#close">
      Cancel
    </button>
  </div>
</dialog>
```

### 6) CSS class conventions (daisyUI-first)

- Prefer daisyUI component classes for UI primitives (buttons, alerts, menus, cards).
- Icons must use Iconify/Lucide:

```html
<span class="icon-[lucide--check] size-4"></span>
```

Markdown typography:

- If rendering Markdown, wrap it using Tailwind Typography + theme mapping:

```html
<div class="prose prose-sm prose-theme max-w-none">
  <!-- Markdown content -->
</div>
```

If `.prose-theme` is used anywhere, it must be implemented in `app/assets/stylesheets/application.tailwind.css` to keep colors aligned with daisyUI themes.

### 7) State convergence (Turbo Stream is truth; ActionCable is best-effort)

Core rule:

- **HTTP Turbo Stream = source of truth** for any state-changing action (success and failure must show UI feedback).
- **ActionCable = best-effort acceleration** (streaming previews, typing indicator, cross-client sync). Losing ActionCable must not permanently drift UI.

Server-side rules:

- For `format.turbo_stream`, return Turbo Stream on success *and* failure (don’t silently `head :unprocessable_entity`).
- Prefer responding with Turbo Streams for “stop/retry/cancel/transition state” endpoints.

Client-side rules:

- If you fetch Turbo Streams via JS, the helper must still **render Turbo Streams even on non-2xx** so errors are visible.
- Avoid duplicating low-level concerns (CSRF, disable/enable, toast). If a shared helper is missing, add it before copying ad-hoc code into controllers.

### 8) Concurrency & race conditions (Turbo replaces re-init controllers)

Turbo Stream `replace` re-initializes controllers; instance fields reset.

Rules:

- Never rely on controller instance fields for “processing locks”.
- Use a module-level global `Map` keyed by a stable id (URL/record id) to prevent rapid-click races.
- For multi-source updates to the same target, use **monotonic revisions**:
  - Server emits an increasing `render_seq` / `revision` (must be DB-backed monotonic).
  - Client ignores stale updates (Turbo `before-stream-render` guard + ActionCable stale-event guard).

### 9) Keyboard shortcuts (intercept only when valid)

- Only `preventDefault()` when the action is actually valid in the current UI state.
- For operations that mutate a message timeline (edit/delete/regenerate/swipe), prefer “tail-only” semantics: operate only on the latest relevant message.

## Token whitelist (strong rules)

If a value is not in this whitelist, treat it as a **design exception** and justify it.

### Icon sizes

- **Default**: `size-4`
- **Nav/major icon**: `size-5`
- **Brand/hero icon**: `size-6`
- Avoid random icon sizes (e.g. `size-3.5`, `size-7`) unless it’s a dedicated illustration.

### Text hierarchy

- **Page title**: `text-2xl font-semibold`
- **Section title**: `text-lg font-semibold`
- **Body**: default
- **Meta text**: `text-sm opacity-70` or `text-xs opacity-60`

### Opacity

- **Secondary/help**: `opacity-70`
- **Tertiary/meta**: `opacity-60`
- Avoid sprinkling `opacity-50/80/90` unless it’s a deliberate exception.

### Shadows (surface)

- **Default surface**: `shadow-sm`
- **Overlay surface (dropdown/toast/modal)**: `shadow-lg`
- Avoid bare `shadow` (too “strong” and inconsistent).

### Radius

- **Containers and code blocks**: `rounded-box`
- Avoid mixing `rounded`, `rounded-md`, `rounded-xl` across similar components.
- Chat composer bubble may use a distinct radius (e.g. `rounded-3xl`) because it’s a unique component.

## Z-index standardization (use Tailwind’s native scale)

Goal: **no custom `z-*` tokens**, no `z-[...]`, and no “random” z-index numbers.

- **Allowed**: `z-0`, `z-10`, `z-20`, `z-30`, `z-40`, `z-50`
- **Avoid**: `z-60`, `z-100`, `z-200`, `z-[123]`, `z-(--var)`

Recommended layering:

- **Base content**: default (no `z-*`)
- **Sticky navbars**: `z-40`
- **Drawers / overlays / dropdowns / toast stack / debug overlays**: `z-50`

If you *must* introduce a new layer:

- First, try to **reduce** layers (remove unnecessary `backdrop-blur`, sticky wrappers, extra positioned containers).
- If still needed, prefer **reusing `z-50`** and moving elements in DOM order over adding new z-index tiers.

## Surface + border + shadow (standard “recipes”)

Keep surface styles consistent by using a small set of “recipes”.

### Default card (most pages)

- **Recipe**: `card bg-base-100 border border-base-300 shadow-sm`

Use this for: login/setup, index pages, non-chat content blocks, most panels.

### Muted settings card (dense tables/forms in settings)

- **Recipe**: `card bg-base-200/30 border border-base-300 shadow-sm`

Use this for: settings panels and tables where you want subtle separation from the page.

### Floating overlays (toasts/dropdowns/modals)

- **Recipe**: `shadow-lg` is OK for overlays.
- Keep the **surface** semantic: `bg-base-100/95` (+ `backdrop-blur-sm` only when it’s clearly intentional).

## Surface recipes (strong rules)

Use these as “approved macros”.

### Card: default surface

- **Recipe**: `card bg-base-100 border border-base-300 shadow-sm`
- Use this for most panels and content blocks.

### Card: settings-muted surface

- **Recipe**: `card bg-base-200/30 border border-base-300 shadow-sm`
- Use this for settings pages and dense tables/forms.

### Table row hover (in settings tables)

- **Recipe**: `hover:bg-base-200/50 transition-colors`
- Avoid inventing new hover mixes like `hover:bg-base-300/20` per-table.

## Spacing standardization

Aim for consistent page rhythm.

- **Page padding**: prefer `p-6` for “agent-like” pages; for wide settings pages use `px-4 md:px-6 lg:px-8` + `py-6 md:py-8`.
- **Section spacing**: prefer `space-y-6` for page sections; `gap-6` for grids.
- **Inline control spacing**: `gap-2` for buttons/inputs; `gap-3` for “icon + label”.

If you see `gap-1`/`gap-4`/`gap-5` used inconsistently for the same pattern, normalize it.

## Opacity standardization

Use a small set of opacities for text hierarchy:

- **Secondary/help text**: `opacity-70`
- **Tertiary/meta text**: `opacity-60`
- Avoid sprinkling `opacity-50/80/90` unless it’s a deliberate exception.

## Color usage rules

Prefer semantic and consistent tokens:

- **Backgrounds**: `bg-base-100` (cards), `bg-base-200` (page/backdrop), `bg-base-200/30` (muted card)
- **Borders**: `border-base-300` (default)
- **Don’t invent per-component variants** like `border-base-300/40` unless it’s a globally adopted pattern.
- **Avoid raw Tailwind palette colors** (`text-gray-700`, `bg-zinc-900`, etc) unless it’s a one-off debug-only element.

## Standard component patterns (copy/paste rules)

Use these shapes to avoid drift.

### Navbar

- **Recipe**: `navbar sticky top-0 z-40 h-14 px-4 md:px-8 border-b bg-base-100 border-base-300`
- Avoid mixing in blur/transparency per-page unless it’s adopted globally.

### Dropdown menu (account)

- **Menu surface**: `bg-base-100/95 backdrop-blur-sm rounded-box shadow-lg border border-base-300 z-50`
- **Menu items**: use `flex items-center gap-2` and icon `size-4` with `shrink-0` for alignment.

### Toasts

- Render inside the single global container (`#toast_container`).
- Toast surface: `alert ... shadow-lg` (consistent with overlay recipe).

## Reuse + extraction rules (partials)

When a UI element appears in multiple places, extract it:

- `app/views/_shared/*` for cross-layout components:
  - Account dropdown/menu items
  - Toast template container (via `layouts/application`)
- `app/views/layouts/agent/*` for agent-layout-only structure:
  - Agent header
  - Agent sidebar sections

## Stimulus/Hotwire conventions (UI-level)

- A `data-controller` should exist only if the controller is **registered** and used.
- Keep controllers **small and single-purpose**; remove dead controllers and unused templates.
- Prefer Turbo/Stimulus-native flows:
  - Server flash → toast rendering in the global toast container
  - Avoid bespoke JS event buses unless multiple pages truly need it

## Pre-merge UI checklist

- Run: `bun run build` and `bun run build:css`
- Run: `bin/rails test`
- Audit:
  - No `z-[...]`, no `z-60/100/200`
  - Cards use one of the surface recipes
  - Similar menus/items use identical `flex/gap/icon size` structure
  - No duplicated layout fragments that should be partials
