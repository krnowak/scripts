#!/bin/bash

function fail() {
  echo "$*" >/dev/stderr
  exit 1
}

if [[ -z "${WORK_SCRIPTS_DIR:-}" ]]; then
  fail "WORK_SCRIPTS_DIR env var unset. It should point to the scripts repo which will be updated."
fi

if [[ ! -d "${WORK_SCRIPTS_DIR:-}" ]]; then
  fail "WORK_SCRIPTS_DIR env var does not point to a directory. It should point to the scripts repo which will be updated."
fi

readonly SDK_OUTER_TOPDIR="${WORK_SCRIPTS_DIR}"
readonly SDK_OUTER_OVERLAY="${SDK_OUTER_TOPDIR}/sdk_container/src/third_party/coreos-overlay"
readonly SDK_INNER_SRCDIR="/mnt/host/source/src"
readonly SDK_INNER_OVERLAY="${SDK_INNER_SRCDIR}/third_party/coreos-overlay"

readonly BUILDBOT_USERNAME="Flatcar Buildbot"
readonly BUILDBOT_USEREMAIL="buildbot@flatcar-linux.org"

function enter() {
  if [[ -z "${PACKAGES_CONTAINER}" ]]; then
    fail "PACKAGES_CONTAINER env var unset. It should contain the name of the SDK container."
  fi
  if [[ -z "${SDK_NAME}" ]]; then
    fail "SDK_NAME env var unset. It should contain the name of the SDK docker image."
  fi
  "${SDK_OUTER_TOPDIR}/run_sdk_container" \
      -n "${PACKAGES_CONTAINER}" \
      -C "${SDK_NAME}" \
      "${@}"
}

# Return a valid ebuild file name for ebuilds of the given category name,
# package name, and the old version. If the single ebuild file already exists,
# then simply return that. If the file does not exist, then we should fall back
# to a similar file including $VERSION_OLD.
# For example, if VERSION_OLD == 1.0 and 1.0.ebuild does not exist, but only
# 1.0-r1.ebuild is there, then we figure out its most similar valid name by
# running "ls -1 ...*.ebuild | sort -ruV | head -n1".
function get_ebuild_filename() {
  local category="${1}"; shift
  local pkg_name="${1}"; shift
  local version_old="${1}"; shift
  local ebuild_basename="${category}/${pkg_name}/${pkg_name}-${version_old}"

  if [[ ! -d "${category}/${pkg_name}" ]]; then
    fail "No such package in '${PWD}': '${category}/${pkg_name}'"
  fi
  if [ -f "${ebuild_basename}.ebuild" ]; then
    echo "${ebuild_basename}.ebuild"
  else
    ls -1 "${ebuild_basename}"*.ebuild | sort --reverse --unique --version-sort | head --lines 1
  fi
}

function prepare_git_repo() {
  git -C "${SDK_OUTER_TOPDIR}" config user.name "${BUILDBOT_USERNAME}"
  git -C "${SDK_OUTER_TOPDIR}" config user.email "${BUILDBOT_USEREMAIL}"
}

function regenerate_manifest() {
  local category_name="${1}"; shift
  local pkg_name="${1}"; shift
  local ebuild_file

  ebuild_file="${SDK_INNER_OVERLAY}/${category_name}/${pkg_name}/${pkg_name}-${VERSION_NEW}.ebuild"
  enter ebuild "${ebuild_file}" manifest --force
}

function join_by() {
  local delimiter="${1-}"
  local first="${2-}"
  if shift 2; then
    printf '%s' "${first}" "${@/#/${delimiter}}";
  fi
}

function generate_update_changelog() {
  local name="${1}"; shift
  local version="${1}"; shift
  local url="${1}"; shift
  local update_name="${1}"; shift
  # rest of parameters are version and link pairs for old versions
  local file
  local -a old_links

  file="changelog/updates/$(date '+%Y-%m-%d')-${update_name}-${version}-update.md"

  if [[ -d changelog/updates ]]; then
    printf '%s %s ([%s](%s)' '-' "${name}" "${version}" "${url}" > "${file}"
    if [[ $# -gt 0 ]]; then
      echo -n ' (includes ' >> "${file}"
      while [[ $# -gt 1 ]]; do
        old_links+=( "[${1}](${2})" )
        shift 2
      done
      printf '%s' "$(join_by ', ' "${old_links[@]}")" >> "${file}"
      echo -n ')' >> "${file}"
    fi
    echo ')' >> "${file}"
  fi
}

function commit_changes() {
  local category_name="${1}"; shift
  local pkg_name="${1}"; shift
  local desc="${1}"; shift
  # rest of parameters are additional directories to add to the commit
  local dir

  regenerate_manifest "${category_name}" "${pkg_name}"

  pushd "${SDK_OUTER_OVERLAY}"

  git add "${category_name}/${pkg_name}"
  if [[ -d changelog ]]; then
    git add changelog
  fi
  for dir; do
    git add "${dir}"
  done
  git commit -a -m "${category_name}/${pkg_name}: Update from ${VERSION_OLD} to ${VERSION_NEW}"

  popd
}
