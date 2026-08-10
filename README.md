# Private Build Controller

This private repository contains generic GitHub Actions orchestration only. Product source is fetched from a private network for a single run, extension releases and service images are delivered directly to internal storage, deployment is performed over the private network, and temporary data is removed unconditionally.

It intentionally does not use GitHub Artifacts, caches, releases, or source mirrors.
