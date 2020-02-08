# Lightweight Source-to-image CLI

Source-to-image (S2I) is a tool for building repeatable container images.

A command line interface that injects and assembles source code into a container image.

This is a podman-compatible lightweight re-implementation of the original source-to-image.
The original implementation (available at http://github.com/openshift/source-to-image)
was written in golang and did not intent to support podman (only worked with the
docker runtime.

This lightweight implementation aims to be usable in the most common use cases and
with any container runtime (docker or podman). However, this implementation does not
aim to re-implement full UI of the original program, so not all options are supported.

## Usage

```
  s2i [flags] <command>

Available Commands:
  build       Build a new image
  usage       Print usage of the assemble script associated with the image
  version     Display version

Flags:
  --args        Arguments passed to the container runtime
  --force-bin   Use only this binary as the container runtime, by default the podman
                is preferred. But if podman is missing, docker is used.

Use 's2i <command> --help' for more information about a command.
```
