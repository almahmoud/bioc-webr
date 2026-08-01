#!/usr/bin/env Rscript
#
# Cross-compile a Bioconductor release into a webR-consumable package
# repository.
#
# Runs inside the r-wasm/webr container (see compose.yaml); it needs the
# Emscripten toolchain on PATH and will not do anything useful on a host.
#
# Configured entirely through the environment:
#
#   BIOC_VERSION    required. e.g. "3.23"
#   BIOC_REPO_URL   required. CRAN-like base URL for the release
#   CRAN_URL        mirror used to install this script's own dependencies
#   RWASM_REF       package reference for rwasm itself
#   SITE_DIR        output directory. Default /site
#   BIOC_PACKAGES   optional. Space-separated package names. When set, builds
#                   ONLY those and their hard dependencies (development path;
#                   see docs/development.md)
#   BIOC_SKIP_REGEX optional. Regular expression of package names to skip
#   REMOTES_MODE    filter (default) | strict | none. How rwasm's bundled
#                   webR-patched package sources are handled; see
#                   resolve_remotes() below

options(warn = 1)

env <- function(name, default = NULL) {
  value <- Sys.getenv(name, unset = NA_character_)
  if (is.na(value) || !nzchar(value)) {
    if (is.null(default)) {
      stop(sprintf("%s is required but not set", name), call. = FALSE)
    }
    return(default)
  }
  value
}

bioc_version <- env("BIOC_VERSION")
bioc_repo_url <- env("BIOC_REPO_URL")
cran_url      <- env("CRAN_URL", "https://cloud.r-project.org")
rwasm_ref     <- env("RWASM_REF", "r-wasm/rwasm")
site_dir      <- env("SITE_DIR", "/site")
subset        <- env("BIOC_PACKAGES", "")
skip_regex    <- env("BIOC_SKIP_REGEX", "")
build_jobs    <- as.integer(env("BUILD_JOBS", "2"))

# `repos` installs this script's own dependencies with the container's native
# R; what gets cross-compiled comes from bioc_repo_url below.
options(
  repos = c(CRAN = cran_url),
  Ncpus = max(1L, build_jobs),
  timeout = 3600  # source tarballs for some Bioconductor data packages are large
)

message("--- Build dependencies -------------------------------------------")

# rwasm ships preinstalled in ghcr.io/r-wasm/webr from v0.6.0; the fallback
# install keeps older WEBR_VERSION images working.
if (!requireNamespace("rwasm", quietly = TRUE)) {
  message("rwasm not present in this image; installing from ", rwasm_ref)
  if (requireNamespace("pak", quietly = TRUE)) {
    pak::pak(rwasm_ref)
  } else {
    if (!requireNamespace("remotes", quietly = TRUE)) install.packages("remotes")
    remotes::install_github(rwasm_ref, upgrade = "never")
  }
}
if (!requireNamespace("rwasm", quietly = TRUE)) {
  stop("failed to install rwasm", call. = FALSE)
}

message("  rwasm      ", as.character(utils::packageVersion("rwasm")))
message("  pkgdepends ", as.character(utils::packageVersion("pkgdepends")))
message("  R (native) ", paste0(R.version$major, ".", R.version$minor))

dir.create(site_dir, recursive = TRUE, showWarnings = FALSE)

# rwasm's bundled webr-remotes list (webR-patched package sources) is resolved
# as one batch by prefer_remotes(), so a single unresolvable reference aborts
# the whole build; with rwasm 0.3.0.9000 / pkgdepends 0.9.1 three of the
# seventeen references fail. A dropped reference means that package is taken
# from upstream sources and may not compile for wasm, hence the loud report.
# See docs/architecture.md for the full background.
#
# REMOTES_MODE:
#   filter (default)  resolve individually, use what works, report the rest
#   strict            rwasm's own behaviour - fail if any reference is bad
#   none              skip the bundled list entirely (upstream sources only)
remotes_mode <- env("REMOTES_MODE", "filter")

resolve_remotes <- function() {
  if (identical(remotes_mode, "none")) {
    message("REMOTES_MODE=none - not using rwasm's webR-patched sources")
    return(NULL)      # prefer_remotes() returns early on NULL
  }
  if (identical(remotes_mode, "strict")) {
    message("REMOTES_MODE=strict - rwasm resolves its bundled list as a batch")
    return(NA)        # rwasm's default
  }

  remotes_file <- system.file("webr-remotes", package = "rwasm")
  if (!nzchar(remotes_file) || !file.exists(remotes_file)) {
    warning("rwasm has no bundled webr-remotes list; continuing without it")
    return(NULL)
  }

  refs <- unique(readLines(remotes_file))
  message("Checking ", length(refs), " bundled webR remotes individually")

  usable <- character(0)
  broken <- character(0)
  for (ref in refs) {
    okay <- tryCatch(
      {
        p <- pkgdepends::new_pkg_download_proposal(
          ref,
          config = getFromNamespace("ppm_config", "rwasm")
        )
        p$resolve()
        TRUE
      },
      error = function(e) FALSE
    )
    if (isTRUE(okay)) usable <- c(usable, ref) else broken <- c(broken, ref)
  }

  if (!length(broken)) {
    message("  All ", length(refs), " bundled remotes resolved.")
    return(NA)
  }

  message("")
  message("  !! ", length(broken), " of ", length(refs),
          " bundled webR remotes could not be resolved:")
  for (b in broken) message("       ", b)
  message("")
  message("     They are excluded. Any package above that this build needs")
  message("     will be taken from upstream sources instead of its")
  message("     webR-patched fork, and may fail to compile.")
  message("     Set REMOTES_MODE=strict to fail here instead.")
  message("")

  if (!length(usable)) {
    message("     No bundled remotes are usable; continuing without any.")
    return(NULL)
  }

  # The usable subset is written over rwasm's bundled file and NA returned so
  # rwasm reads it through its normal code path - prefer_remotes()' `remotes=`
  # only accepts NA or NULL in practice. The edit lives in the disposable
  # container layer; nothing on the host or in a named volume is touched.
  writeLines(usable, remotes_file)
  message("     Continuing with the ", length(usable), " that resolved.")
  NA
}

remotes_arg <- resolve_remotes()

started <- Sys.time()

if (nzchar(subset)) {
  # ---------------------------------------------------------------- subset
  # `bioc::` is a pkgdepends reference type - bare names would resolve against
  # CRAN only. dependencies = NA keeps hard dependencies; rwasm's default
  # (FALSE) would leave the subset uninstallable.
  pkgs <- strsplit(trimws(subset), "[[:space:],]+")[[1]]
  pkgs <- pkgs[nzchar(pkgs)]
  refs <- ifelse(grepl("::|/", pkgs), pkgs, paste0("bioc::", pkgs))

  message("--- Building SUBSET: ", paste(pkgs, collapse = ", "), " ---------")
  message("    (development mode - the result is NOT a complete release)")

  rwasm::add_pkg(
    refs,
    repo_dir = site_dir,
    remotes = remotes_arg,
    dependencies = NA
  )

  writeLines(
    c(
      "This repository was built from a package subset and is INCOMPLETE.",
      "It is a development artifact. Do not publish it.",
      "",
      paste("Requested:", paste(pkgs, collapse = ", ")),
      paste("Bioconductor:", bioc_version),
      paste("Built:", format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"))
    ),
    file.path(site_dir, "INCOMPLETE")
  )
} else {
  # ---------------------------------------------------------------- full
  message("--- Building FULL release from ", bioc_repo_url, " -------------")

  args <- list(bioc_repo_url, repo_dir = site_dir, remotes = remotes_arg)
  if (nzchar(skip_regex)) {
    message("    Skipping packages matching: ", skip_regex)
    args$skip <- skip_regex
  }
  do.call(rwasm::add_repo, args)

  unlink(file.path(site_dir, "INCOMPLETE"))
}

elapsed <- difftime(Sys.time(), started, units = "mins")

# rwasm lays the repository out CRAN-style: binaries under
# bin/emscripten/contrib/<r-version>/.
built <- list.files(site_dir, pattern = "\\.tgz$", recursive = TRUE)

message("--- Done --------------------------------------------------------")
message("  Packages built : ", length(built))
message("  Elapsed        : ", format(round(elapsed, 1)))
message("  Output         : ", site_dir)

# A build that produces nothing has failed, whatever rwasm returned; refuse to
# index an empty tree as success.
if (length(built) == 0L) {
  stop("no packages were built - refusing to report success", call. = FALSE)
}

# Provenance: lets a published tree be traced back to what produced it.
writeLines(
  c(
    paste("bioc_version:", bioc_version),
    paste("bioc_repo_url:", bioc_repo_url),
    paste("rwasm_version:", as.character(utils::packageVersion("rwasm"))),
    paste("r_version:", paste0(R.version$major, ".", R.version$minor)),
    paste("packages_built:", length(built)),
    paste("built_at:", format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")),
    paste("subset:", if (nzchar(subset)) subset else "none (full release)")
  ),
  file.path(site_dir, "BUILDINFO")
)
