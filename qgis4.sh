#!/usr/bin/env bash
# qgis4.sh - Run dockerized QGIS (GUI) on Ubuntu 24.04
#
# Usage:
#   ./qgis4.sh                      # start QGIS with the default version
#   ./qgis4.sh /path/project.qgz    # open a project (must be under $QGIS_DATA_DIR)
#   QGIS_TAG=final-4_2_4 ./qgis4.sh # force a specific tag
#   ./qgis4.sh --pull               # pull/update the image and exit
#   ./qgis4.sh --shell              # shell inside the container (debug)
#   ./qgis4.sh --process -- <args>  # run qgis_process with the given arguments
#
# Configurable variables (override via environment):
#   QGIS_IMAGE      Docker image                   (default: qgis/qgis)
#   QGIS_TAG        image tag                      (default: final-4_2_4)
#   QGIS_DATA_DIR   data folder mounted on /data   (default: ~/qgis-data)
#   QGIS_HOME_DIR   persistent profile/config      (default: ~/.local/share/qgis4-docker)
#   QGIS_GPU        1 to expose /dev/dri (Intel/AMD GPU acceleration) (default: 1)

set -euo pipefail

QGIS_IMAGE="${QGIS_IMAGE:-qgis/qgis}"
QGIS_TAG="${QGIS_TAG:-4.2.3-resolute}"
QGIS_DATA_DIR="${QGIS_DATA_DIR:-$HOME/qgis-data}"
QGIS_HOME_DIR="${QGIS_HOME_DIR:-$HOME/.local/share/qgis4-docker}"
QGIS_GPU="${QGIS_GPU:-1}"
IMAGE="${QGIS_IMAGE}:${QGIS_TAG}"

err()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# --- Preliminary checks ----------------------------------------------------
command -v docker >/dev/null 2>&1 || err "Docker not installed. Run: sudo apt install -y docker.io && sudo usermod -aG docker \$USER (then log in again)"
docker info >/dev/null 2>&1 || err "Cannot reach the Docker daemon (service stopped or user not in the 'docker' group)."

pull_image() {
    info "Pulling image ${IMAGE} ..."
    if ! docker pull "${IMAGE}"; then
        cat >&2 <<EOF

Unable to pull ${IMAGE}.
The tag may not exist or may have a different format.
Check the available tags at: https://hub.docker.com/r/${QGIS_IMAGE}/tags
then run again, for example:
    QGIS_TAG=<tag-corretto> $0
EOF
        exit 1
    fi
}

# --- --pull option ---------------------------------------------------------
if [[ "${1:-}" == "--pull" ]]; then
    pull_image
    exit 0
fi

# Pull the image only if not available locally
if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    pull_image
fi

mkdir -p "${QGIS_DATA_DIR}" "${QGIS_HOME_DIR}"

# --- Common docker run arguments ------------------------------------------
DOCKER_ARGS=(
    --rm
    --name "qgis4-$$"
    --user "$(id -u):$(id -g)"
    -e HOME=/home/qgis
    -e XDG_RUNTIME_DIR=/tmp/runtime
    -v "${QGIS_HOME_DIR}:/home/qgis"
    -v "${QGIS_DATA_DIR}:/data"
    -w /data
)

# --- Non-graphical modes ---------------------------------------------------
case "${1:-}" in
    --shell)
        info "Shell in container ${IMAGE}"
        exec docker run -it "${DOCKER_ARGS[@]}" "${IMAGE}" bash
        ;;
    --process)
        shift
        [[ "${1:-}" == "--" ]] && shift
        exec docker run -it "${DOCKER_ARGS[@]}" -e QT_QPA_PLATFORM=offscreen \
            "${IMAGE}" qgis_process "$@"
        ;;
esac

# --- GUI mode (X11 / XWayland) --------------------------------------------
[[ -n "${DISPLAY:-}" ]] || err "\$DISPLAY not set: a graphical session is required (X11 or XWayland)."
command -v xhost >/dev/null 2>&1 || err "xhost missing. Install with: sudo apt install -y x11-xserver-utils"

info "Granting the container access to the X display"
xhost +local:docker >/dev/null
trap 'xhost -local:docker >/dev/null 2>&1 || true' EXIT

DOCKER_ARGS+=(
    -e DISPLAY="${DISPLAY}"
    -e QT_X11_NO_MITSHM=1
    -v /tmp/.X11-unix:/tmp/.X11-unix:rw
    --tmpfs /tmp/runtime:mode=0700,uid="$(id -u)",gid="$(id -g)"
)

# GPU acceleration (Intel/AMD) if available
if [[ "${QGIS_GPU}" == "1" && -d /dev/dri ]]; then
    DOCKER_ARGS+=( --device /dev/dri )
    # video/render groups to access the GPU as non-root user
    for g in video render; do
        gid="$(getent group "$g" | cut -d: -f3 || true)"
        [[ -n "${gid}" ]] && DOCKER_ARGS+=( --group-add "${gid}" )
    done
fi

# Optional file to open, passed as argument
QGIS_CMD=(qgis)
if [[ $# -gt 0 ]]; then
    f="$(realpath -m "$1")"
    case "$f" in
        "${QGIS_DATA_DIR}"/*) QGIS_CMD+=( "/data/${f#"${QGIS_DATA_DIR}"/}" ) ;;
        *) err "The file must be under ${QGIS_DATA_DIR} (mounted as /data in the container)." ;;
    esac
fi

info "Starting QGIS (${IMAGE})"
info "Data: ${QGIS_DATA_DIR} -> /data | Profile: ${QGIS_HOME_DIR}"
docker run -it "${DOCKER_ARGS[@]}" "${IMAGE}" "${QGIS_CMD[@]}"
