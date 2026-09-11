#!/usr/bin/env bash
set -Eeu

readonly REGEX="image_name\": \"(.*)\""
readonly JSON=`cat docker/image_name.json`
[[ ${JSON} =~ ${REGEX} ]]
readonly IMAGE_NAME="${BASH_REMATCH[1]}"

# install.sh resolves ginkgo and gomega with go mod tidy and records what it
# got in /versions.json, so the versions are read from the image rather than
# written down here. Writing them down here would pin the image to whatever
# was current when someone last edited this file.
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
