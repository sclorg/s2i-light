#!/bin/sh
# 
# Copyright Red Hat
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -e

_force_runtime=''

_get_runtime() {
    if [ -n "$_force_runtime" ] ; then
        echo "$_force_runtime"
        return
    fi
    for c in podman docker ; do
        if command -v "$c" >/dev/null ; then
            echo "$c"
            return
        fi
    done
    return 1
}

_s2i_usage_help() {
  echo "Create and start a container from the image and invoke its usage script.

Usage:
  s2i usage <image>"
}

# _s2i_usage IMG_NAME [S2I_ARGS]
# ----------------------------
# Create a container and run the usage script inside
# Argument: IMG_NAME - name of the image to be used for the container run
# Argument: S2I_ARGS - Additional list of source-to-image arguments, currently unused.
_s2i_usage()
{
    if [ $# -eq 0 ] ; then
        perror "Image name was not specified."
        echo
        print_help
        exit 1
    fi

    case $1 in
        -h|--help|help) _s2i_usage_help ; return ;;
    esac

    local img_name=$1; shift
    local s2i_args="$*";
    local usage_command="/usr/libexec/s2i/usage"
    $(_get_runtime) run --rm "$img_name" bash -c "$usage_command"
}

_s2i_build_as_df_help() {
echo "Build a new container image named <tag> (if provided) from a source repository and base image.

Usage:
  s2i build <source> <image> <tag> [flags]

Examples:

# Build a container image from a remote Git repository
$ s2i build https://github.com/openshift/ruby-hello-world centos/ruby-26-centos7 hello-world-app

# Build from a local directory
$ s2i build . centos/ruby-26-centos7 hello-world-app

Flags:
  -e, --env string                       Specify an single environment variable in NAME=VALUE format
  -p, --pull-policy string               Specify when to pull the builder image (always, never or if-not-present) (default 'if-not-present')
      --incremental                      Perform an incremental build
"
}

# _s2i_build_as_df APP_PATH SRC_IMAGE DST_IMAGE [S2I_ARGS]
# ----------------------------
# Create a new s2i app image from local sources in a similar way as source-to-image would have used.
# Argument: APP_PATH - local path to the app sources to be used in the test
# Argument: SRC_IMAGE - image to be used as a base for the s2i build
# Argument: DST_IMAGE - image name to be used during the tagging of the s2i build result
# Argument: S2I_ARGS - Additional list of source-to-image arguments.
#                      Only used to check for pull-policy=never and environment variable definitions.
_s2i_build_as_df()
{
    [ $# -lt 1 ] && perror "Application path or URL was not specified."

    case $1 in
        -h|--help|help) _s2i_build_as_df_help ; return ;;
    esac

    [ $# -lt 2 ] && perror "Source Image name was not specified."
    [ $# -lt 3 ] && perror "Destination Image name was not specified."

    if [ $# -lt 3 ] ; then
        echo
        _s2i_build_as_df_help
        exit 1
    fi

    local app_path=$1; shift
    local src_image=$1; shift
    local dst_image=$1; shift
    local s2i_args="$*";
    local local_app=upload/src/
    local local_scripts=upload/scripts/
    local user_id=
    local df_name=
    local tmpdir=
    local incremental=false
    local mount_options=""

    # Run the entire thing inside a subshell so that we do not leak shell options outside of the function
    (
    # Error out if any part of the build fails
    set -e

    # Use /tmp to not pollute cwd
    tmpdir=$(mktemp -d)
    df_name=$(mktemp -p "$tmpdir" Dockerfile.XXXX)
    cd "$tmpdir"

    # Check if the image is available locally and try to pull it if it is not
    $(_get_runtime) images | grep -q ^"${src_image}\s" || echo "$s2i_args" | grep -q -e "pull-policy=never" -e "-p=never" || $(_get_runtime) pull "$src_image"
    user=$($(_get_runtime) inspect -f "{{.Config.User}}" "$src_image")

    # Default to root if no user is set by the image
    user=${user:-0}
    # run the user through the image in case it is non-numeric or does not exist
    # NOTE: The '-eq' test is used to check if $user is numeric as it will fail if $user is not an integer
    if ! [ "$user" -eq "$user" ] 2>/dev/null && ! user_id=$($(_get_runtime) run --rm "$src_image" bash -c "id -u $user 2>/dev/null"); then
        echo "ERROR: id of user $user not found inside image $src_image."
        echo "Terminating s2i build."
        return 1
    else
        user_id=${user_id:-$user}
    fi

    # parse the args to see whether incremental build requested
    echo "$s2i_args" | grep -q -e "\-\-incremental" && incremental=true
    if $incremental; then
        inc_tmp=$(mktemp -d --tmpdir incremental.XXXX)
        setfacl -m "u:$user_id:rwx" "$inc_tmp"
        # Check if the image exists, build should fail (for testing use case) if it does not
        $(_get_runtime) images "$dst_image" &>/dev/null || (echo "Image $dst_image not found."; false)
        # Run the original image with a mounted in volume and get the artifacts out of it
        cmd="if [ -s /usr/libexec/s2i/save-artifacts ]; then /usr/libexec/s2i/save-artifacts > \"$inc_tmp/artifacts.tar\"; else touch \"$inc_tmp/artifacts.tar\"; fi"
        $(_get_runtime) run --rm -v "$inc_tmp:$inc_tmp:Z" "$dst_image" bash -c "$cmd"
        # Move the created content into the $tmpdir for the build to pick it up
        mv "$inc_tmp/artifacts.tar" "$tmpdir/"
    fi

    # Strip file:// from APP_PATH and copy its contents into current context
    if echo "$app_path" | grep -qe '^\(git:\/\/\|git+ssh:\/\/\|http:\/\/\|https:\/\/\)' ; then
        git clone "$app_path" "$local_app"
    else
        mkdir -p "$local_app"
        cp -r "${app_path/file:\/\//}/." "$local_app"
    fi

    [ -d "$local_app/.s2i/bin/" ] && mv "$local_app/.s2i/bin" "$local_scripts"

    # Create a Dockerfile named df_name and fill it with proper content
    #FIXME: Some commands could be combined into a single layer but not sure if worth the trouble for testing purposes
    cat <<EOF >"$df_name"
FROM $src_image
LABEL "io.openshift.s2i.build.image"="$src_image" \\
      "io.openshift.s2i.build.source-location"="$app_path"
USER root
COPY $local_app /tmp/src
EOF
    [ -d "$local_scripts" ] && echo "COPY $local_scripts /tmp/scripts" >> "$df_name" &&
    echo "RUN chown -R $user_id:0 /tmp/scripts" >>"$df_name"
    echo "RUN chown -R $user_id:0 /tmp/src" >>"$df_name"
    # Check for custom environment variables inside .s2i/ folder
    if [ -e "$local_app/.s2i/environment" ]; then
        # Remove any comments and add the contents as ENV commands to the Dockerfile
        sed '/^\s*#.*$/d' "$local_app/.s2i/environment" | while read -r line; do
            echo "ENV $line" >>"$df_name"
        done
    fi

    # Filter out env var definitions from $s2i_args and create Dockerfile ENV commands out of them
    echo "$s2i_args" | grep -o -e '\(-e\|--env\)[[:space:]=]\S*=\S*' | sed -e 's/-e /ENV /' -e 's/--env[ =]/ENV /' >>"$df_name"

    # Add in artifacts if doing an incremental build
    if $incremental; then
        { echo "RUN mkdir /tmp/artifacts"
          echo "ADD artifacts.tar /tmp/artifacts"
          echo "RUN chown -R $user_id:0 /tmp/artifacts" ; } >>"$df_name"
    fi

    echo "USER $user_id" >>"$df_name"
    # If exists, run the custom assemble script, else default to /usr/libexec/s2i/assemble
    if [ -x "$local_scripts/assemble" ]; then
        echo "RUN /tmp/scripts/assemble" >>"$df_name"
    else
        echo "RUN /usr/libexec/s2i/assemble" >>"$df_name"
    fi
    # If exists, set the custom run script as CMD, else default to /usr/libexec/s2i/run
    if [ -x "$local_scripts/run" ]; then
        echo "CMD /tmp/scripts/run" >>"$df_name"
    else
        echo "CMD /usr/libexec/s2i/run" >>"$df_name"
    fi

    # Check if -v parameter is present in s2i_args and add it into _get_runtime build command
    mount_options=$(echo "$s2i_args" | grep -o -e '\(-v\)[[:space:]]\.*\S*' || true)

    # Run the build and tag the result
    # shellcheck disable=SC2086
    $(_get_runtime) build $mount_options -f "$df_name" --no-cache=true -t "$dst_image" .
    echo
    echo "Image $dst_image successfully built."
    )
}

print_help() {
  echo "Source-to-image (S2I) is a tool for building repeatable container images.

A command line interface that injects and assembles source code into a container image.

This is a podman-compatible lightweight re-implementation of the original source-to-image.
The original implementation (available at http://github.com/openshift/source-to-image)
was written in golang and did not intent to support podman (only worked with the
docker runtime.

This lightweight implementation aims to be usable in the most common use cases and
with any container runtime (docker or podman). However, this implementation does not
aim to re-implement full UI of the original program, so not all options are supported.

Complete documentation is available at http://github.com/sclorg/s2i-light.

Usage:
  s2i [flags] <command>

Available Commands:
  build       Build a new image
  usage       Print usage of the assemble script associated with the image
  version     Display version

Flags:
  --args        Arguments passed to the container runtime
  --force-bin   Use only this binary as the container runtime, by default the podman
                is preferred. But if podman is missing, docker is used.

Use 's2i <command> --help' for more information about a command."
}

perror() {
  echo "ERROR: $*" >&2
}

if [ $# -eq 0 ] ; then
  print_help
  exit 1
fi

case $1 in
  -h|--help|help) print_help ; exit 0 ;;
  usage) shift ; _s2i_usage $@ ;;
  build) shift ; _s2i_build_as_df $@ ;;
  *) perror "Unknown command." ; print_help ; exit 1 ;;
esac

