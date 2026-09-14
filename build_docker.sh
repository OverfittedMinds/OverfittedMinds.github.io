#!/usr/bin/env bash
set -euo pipefail

image_name="registry.git.pg.edu.pl/p966564/overfittedminds-docker-image:latest"

publish=false
while getopts "p" opt; do
  case $opt in
    p) publish=true;;
    \?) echo "Usage: docker build [-p]" >&2
        exit 1 ;;
  esac
done

echo "Building image"
docker build -t "$image_name" .

if [ "$publish" = true ]; then
  echo "Publishing the image"
  docker push "$image_name"
fi