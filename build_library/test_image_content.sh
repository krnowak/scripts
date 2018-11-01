# Copyright (c) 2012 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

GLSA_WHITELIST=(
	201412-09 # incompatible CA certificate version numbers
	201710-23 # we handle Go differently; drop when 1.9 builds everything
	201803-03 # same as above, drop when all Go < 1.9 packages are gone
	201804-12 # same as above, except this requires only Go 1.10 or later
	201810-10 # we fixed the systemd CVEs in 238, but this wants 239
)

glsa_image() {
  if glsa-check-$BOARD -t all | grep -Fvx "${GLSA_WHITELIST[@]/#/-e}"; then
    echo "The above GLSAs apply to $ROOT"
    return 1
  fi

  return 0
}

test_image_content() {
  local root="$1"
  local returncode=0

  info "Checking $1"
  local check_root="${BUILD_LIBRARY_DIR}/check_root"
  if ! ROOT="$root" "$check_root" libs; then
    warn "test_image_content: Failed dependency check"
    warn "This may be the result of having a long-lived SDK with binary"
    warn "packages that predate portage 2.2.18. If this is the case try:"
    echo "    emerge-$BOARD -agkuDN --rebuilt-binaries=y -j9  @world"
    echo "    emerge-$BOARD -a --depclean"
    #returncode=1
  fi

  local blacklist_dirs=(
    "$root/usr/share/locale"
  )
  for dir in "${blacklist_dirs[@]}"; do
    if [ -d "$dir" ]; then
      warn "test_image_content: Blacklisted directory found: $dir"
      # Only a warning for now, size isn't important enough to kill time
      # playing whack-a-mole on things like this this yet.
      #error "test_image_content: Blacklisted directory found: $dir"
      #returncode=1
    fi
  done

  # Check that there are no conflicts between /* and /usr/*
  if ! ROOT="$root" "$check_root" usr; then
    error "test_image_content: Failed /usr conflict check"
    returncode=1
  fi

  # Check that there are no #! lines pointing to non-existant locations
  if ! ROOT="$root" "$check_root" shebang; then
    warn "test_image_content: Failed #! check"
    # Only a warning for now. We still have to actually remove all of the
    # offending scripts.
    #error "test_image_content: Failed #! check"
    #returncode=1
  fi

  if ! sudo ROOT="$root" "$check_root" symlink; then
    error "test_image_content: Failed symlink check"
    returncode=1
  fi

  if ! ROOT="$root" glsa_image; then
      returncode=1
  fi

  return $returncode
}
