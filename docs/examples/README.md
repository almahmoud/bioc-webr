# Examples

## Using the repository from webR

Each section below says what has been run and what is written from webR's
documented interface; parts marked **unverified** have not been run in a
browser.

| | Status |
|---|---|
| Installing a package from the repository in a browser webR session | **verified** against 3.22 — see below |
| A runnable HTML page demonstrating it | [`demo/`](../../demo/) — **partly verified**, see [The demo page](#the-demo-page) |
| Using it from `webr` in Node | not written |
| Pointing Quarto (`quarto-live`) at the repository | **written, render-verified** — see [Quarto](#quarto-quarto-live--render-verified); runtime install not run |
| Which Bioconductor packages work under webR | **unknown** — not tested |

A wasm build can succeed and the package
can still be unusable in a browser — anything relying on threads, sockets,
subprocesses, or a real filesystem may compile and then fail at runtime. Nothing
here tests that.

### Installing from the repository

webR's `installPackages()` takes repository URLs, the same shape as R's
`repos`. A published release is a CRAN-like repository at:

```
https://webr.bioconductor.org/<release>
```

That is the directory *containing* `bin/emscripten/`, not the
`bin/emscripten/contrib/<r-version>/` directory itself. List
`https://repo.r-wasm.org` after it for CRAN dependencies.

The same call against 3.22 with webR `v0.5.9` is verified (see
[Verification status](#verification-status)); the 3.23 form below, with webR
`v0.6.0`, is **unverified**.

```html
<script type="module">
  import { WebR } from 'https://webr.r-wasm.org/v0.6.0/webr.mjs';

  const webR = new WebR();
  await webR.init();

  await webR.installPackages(['BiocGenerics'], {
    repos: ['https://webr.bioconductor.org/3.23', 'https://repo.r-wasm.org']
  });

  const result = await webR.evalR('packageVersion("BiocGenerics")');
  console.log(await result.toString());
</script>
```

**The webR version must match `WEBR_VERSION`.** A webR release fixes the ABI of
every `.wasm` it produces; a browser running one version is not guaranteed to
load packages built by another. See
[operations.md](../operations.md#webr_version-is-not-a-preference).

### The demo page

[`demo/index.html`](../../demo/) is a single self-contained page that boots
webR, installs Bioconductor packages from a published repository, and runs
editable R with both text and plot output. No build step, no dependencies, no
server-side anything — it needs only a static host.

The page is not deployed. It is one static file and can be served from any
static host.

#### The two pins at the top of the file

```js
const WEBR_VERSION = 'v0.5.9';   // ships R 4.5.1
const BIOC_VERSION = '3.22';     // published for R 4.5
```

These must agree on their R version, for the reason in
[operations.md](../operations.md#webr_version-is-not-a-preference): a webR
release fixes the ABI of every package built for it, and a mismatch fails as
`package not available` with nothing pointing at the cause. Do not change one
without checking the other, and do not use `latest` — it will move onto a webR
whose R version does not match the published packages, and the page will break
for readers with no visible error.

#### Trying it against a local build

The `serve` profile mounts `demo/` alongside the repository, so a page served
from localhost can be pointed at a tree you just built:

```bash
docker compose run --rm build
docker compose --profile serve up serve
```

Then open <http://localhost:8080/demo/?repo=http://localhost:8080/>.

The local build has to target the R version of the page's webR. With the pins
above (webR `v0.5.9`, R 4.5), set `WEBR_VERSION=v0.5.9` and `BIOC_VERSION=3.22`
in `.env` before building; the `.env.example` defaults, `v0.6.0` and 3.23,
build for R 4.6, and the page then reports `package not available`. To test an
R 4.6 build instead, change the page's two pins to `v0.6.0` and `3.23` while
testing.

The `?repo=` override is honoured **only** when the page is served from
localhost. On a public page it would let a crafted link make a visitor install
packages from an arbitrary origin.

The examples in the page reference Bioconductor packages, so a subset build
needs to include them (or edit the `EXAMPLES` array to match what you built).

#### Verification status

**Verified in a browser:** the install path. webR `v0.5.9` against
`https://webr.bioconductor.org/3.22` installs `S4Vectors` and evaluates R
returning real output, in roughly seven seconds including the webR download.

**Not verified:** this page as a whole. Specifically, the graphics path uses
`Shelter.captureR({ captureGraphics: true })` and the `GenomicRanges` and plot
examples have not been run. They are written from webR's documented interface.
`captureGraphics` needs `OffscreenCanvas`, which rules out older Safari.

### Testing against a local build

This part *is* verified — the `serve` profile works and returns the repository
over HTTP with permissive CORS:

```bash
# .env
BIOC_VERSION=3.23
BIOC_PACKAGES=BiocGenerics

docker compose run --rm build
docker compose --profile serve up serve
```

```bash
curl -s http://localhost:8080/bin/emscripten/contrib/4.6/PACKAGES | head
curl -sI http://localhost:8080/ | grep -i access-control
```

Then point a webR session at `http://localhost:8080/`. Serve the page over HTTP
as well — a page on HTTPS cannot fetch from `http://localhost`.

### Quarto (`quarto-live`) — *render verified*

[quarto-live](https://r-wasm.github.io/quarto-live/) is the r-wasm team's
Quarto extension: a fenced `{webr}` block becomes an editable, runnable code
cell in the rendered page. Pointing it at this repository is YAML only:

```yaml
---
format: live-html
engine: knitr
webr:
  packages:
    - S4Vectors
  repos:
    - https://webr.bioconductor.org/3.23
    - https://repo.r-wasm.org
---

{{< include ./_extensions/r-wasm/live/_knitr.qmd >}}
```

after `quarto add r-wasm/quarto-live`, with code cells written as
````markdown
```{webr}
library(S4Vectors)
DataFrame(gene = c("TP53", "BRCA1"), count = c(120L, 45L))
```
````

**Verified (2026-08-08):** a document with exactly this YAML renders with
Quarto 1.10 and the extension release of that date, and the rendered page's embedded
`webr-data` payload decodes to

```json
{"options":{"baseUrl":"https://webr.r-wasm.org/v0.6.0/"},
 "packages":{"pkgs":["evaluate","knitr","htmltools","S4Vectors"],
             "repos":["https://webr.bioconductor.org/3.23",
                      "https://repo.r-wasm.org"]}}
```

— the extension passes the repositories through unmodified, and bundles its
**own** webR engine (v0.6.0, R 4.6). The
`WEBR_VERSION` contract from
[operations.md](../operations.md#webr_version-is-not-a-preference) therefore
applies to the *extension*, not to a pin in the document: an R 4.6 engine
needs a repository built for R 4.6. To point a quarto-live page at the
published 3.22 repository instead, pin an R 4.5 engine explicitly with the
`engine-url` document option (e.g. `https://webr.r-wasm.org/v0.5.9/`).

**Not verified:** package installation at page load. The extension's R 4.6
engine matches the published 3.23 repository; installing from it has not been
run in a browser.

### Not verified

- Installing a package in a browser from the published 3.23 repository with
  webR `v0.6.0`.
- The demo page's graphics capture and its `GenomicRanges` and plot examples.
- Using the repository from `webr` in Node.
- Which Bioconductor packages are usable under webR and which fail at runtime.
