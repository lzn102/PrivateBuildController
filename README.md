# Private Build Controller

This private repository contains generic GitHub Actions orchestration only. Product source is fetched from a private network for a single run. Service images are compressed, encrypted, and relayed through a random temporary R2 object; N100 downloads and decrypts the image, pushes it to the internal Gitea Registry, and deploys it. The relay object and all temporary data are removed unconditionally.

It intentionally does not use GitHub Artifacts, caches, releases, or source mirrors. R2 object names contain no project name, and objects are unreadable without the per-build relay key.
