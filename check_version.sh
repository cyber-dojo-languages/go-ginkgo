#!/usr/bin/env bash
set -Eeu

readonly REGEX="image_name\": \"(.*)\""
readonly JSON=`cat docker/image_name.json`
[[ ${JSON} =~ ${REGEX} ]]
readonly IMAGE_NAME="${BASH_REMATCH[1]}"

# install.sh pins ginkgo and gomega and records them in /versions.json, so the
# versions are read from the image rather than written down a second time here.
readonly VERSIONS=$(docker run --rm -i ${IMAGE_NAME} sh -c 'cat /versions.json')

for library in ginkgo gomega; do
  regex="\"${library}\":\"([0-9.]+)\""
  if [[ ! ${VERSIONS} =~ ${regex} ]]; then
    echo "VERSION ERROR: /versions.json has no ${library} property"
    echo "VERSION   FILE: ${VERSIONS}"
    exit 42
  fi
  echo "VERSION CONFIRMED as ${library} ${BASH_REMATCH[1]}"
done
