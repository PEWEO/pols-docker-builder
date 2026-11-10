# pols Docker builder

Docker builds on [pols](https://pols.so) runners that reuse the layers of
your repository's earlier builds. BuildKit runs next to the job with its
state on the pols runner cache, which stays between jobs, so a build only
redoes the steps whose inputs changed. No registry or `type=gha` cache to set
up.

Replace `docker/setup-buildx-action` and `docker/build-push-action`:

```yaml
jobs:
  image:
    runs-on: pols-default
    steps:
      - uses: PEWEO/pols-checkout@v1
      - uses: PEWEO/pols-docker-builder@v1
      - uses: PEWEO/pols-docker-builder/build@v1
        with:
          push: true
          tags: ghcr.io/acme/app:latest
```

`PEWEO/pols-docker-builder` takes the inputs of `docker/setup-buildx-action`
and gives its outputs, plus `cached`. `PEWEO/pols-docker-builder/build` takes
the inputs of `docker/build-push-action` and gives its outputs; on its own it
sets up the cached builder first, so replacing only `build-push-action` works
too.

## How it works

On a pols runner (`runs-on: pols-<size>`), each job gets a copy of its
repository's cache disk, mounted at `/mnt/pols-cache`, and the runner's
environment names a status file that says so. The builder waits for it (up
to `cache-wait` seconds, 60 by default), starts BuildKit (a pinned release,
checked against its published SHA-256 and kept on the cache) with its state
in `/mnt/pols-cache/buildkit`, and makes it the job's Buildx builder.

- A job's copy becomes the cache only when the job succeeds. Jobs of a pull
  request from a fork read the cache but never write to it.
- BuildKit collects garbage by the cache's size: it keeps at most three fifths
  of the disk for layers.
- `type=gha` entries in `cache-from` and `cache-to` are left out while the
  cache is in use; other cache sources and destinations are passed on.
- `driver` and `driver-opts` do not apply on a pols runner.
- Anywhere else (GitHub's runners, your own) these are
  `docker/setup-buildx-action` and `docker/build-push-action`, with the same
  inputs.

## License

MIT
