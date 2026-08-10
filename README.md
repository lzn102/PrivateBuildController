# Private Build Controller

This private repository contains generic GitHub Actions orchestration only. Product source is fetched from a private network for a single run, outputs are delivered directly to the internal registry, and temporary data is removed unconditionally.

It intentionally does not use GitHub Artifacts, caches, releases, or source mirrors.
