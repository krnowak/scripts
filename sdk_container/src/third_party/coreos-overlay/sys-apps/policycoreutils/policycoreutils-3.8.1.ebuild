# Copyright 1999-2025 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI="8"
PYTHON_COMPAT=( python3_{10..13} )
PYTHON_REQ_USE="xml(+)"

inherit python-r1 toolchain-funcs bash-completion-r1

MY_PV="${PV//_/-}"
MY_P="${PN}-${MY_PV}"
EXTRAS_VER="1.37"

DESCRIPTION="SELinux core utilities"
HOMEPAGE="https://github.com/SELinuxProject/selinux/wiki"

if [[ ${PV} == 9999 ]]; then
	inherit git-r3
	EGIT_REPO_URI="https://github.com/SELinuxProject/selinux.git"
	SRC_URI="!vanilla? ( https://dev.gentoo.org/~perfinion/distfiles/policycoreutils-extra-${EXTRAS_VER}.tar.bz2 )"
	S1="${WORKDIR}/${P}/${PN}"
	S2="${WORKDIR}/policycoreutils-extra"
	S="${S1}"
else
	SRC_URI="https://github.com/SELinuxProject/selinux/releases/download/${MY_PV}/${MY_P}.tar.gz
		!vanilla? ( https://dev.gentoo.org/~perfinion/distfiles/policycoreutils-extra-${EXTRAS_VER}.tar.bz2 )"
	KEYWORDS="amd64 arm arm64 x86"
	S1="${WORKDIR}/${MY_P}"
	S2="${WORKDIR}/policycoreutils-extra"
	S="${S1}"
fi

LICENSE="GPL-2"
SLOT="0"
IUSE="audit pam split-usr vanilla +python"
REQUIRED_USE="
	!vanilla? ( python ${PYTHON_REQUIRED_USE} )
"

DEPEND="
	python? (
		>=sys-libs/libselinux-${PV}:=[python,${PYTHON_USEDEP}]
		>=sys-libs/libsemanage-${PV}:=[python(+),${PYTHON_USEDEP}]
		audit? ( >=sys-process/audit-1.5.1[python,${PYTHON_USEDEP}] )
		${PYTHON_DEPS}
	)
	!python? (
		>=sys-libs/libselinux-${PV}:=
		>=sys-libs/libsemanage-${PV}:=
		audit? ( >=sys-process/audit-1.5.1 )
	)
	>=sys-libs/libsepol-${PV}:=
	sys-libs/libcap-ng:=
	pam? ( sys-libs/pam:= )
	!vanilla? (
		>=app-admin/setools-4.2.0[${PYTHON_USEDEP}]
	)
"

# Avoid dependency loop in the cross-compile case, bug #755173
# (Still exists in native)
BDEPEND="sys-devel/gettext"

# pax-utils for scanelf used by rlpkg
RDEPEND="${DEPEND}
	app-misc/pax-utils"

PDEPEND="sys-apps/semodule-utils
	python? ( sys-apps/selinux-python )"

src_unpack() {
	# Override default one because we need the SRC_URI ones even in case of 9999 ebuilds
	default
	if [[ ${PV} == 9999 ]] ; then
		git-r3_src_unpack
	fi
}

src_prepare() {
	S="${S1}"
	cd "${S}" || die "Failed to switch to ${S}"
	if [[ ${PV} != 9999 ]] ; then
		# If needed for live ebuilds please use /etc/portage/patches
		eapply "${FILESDIR}/policycoreutils-3.1-0001-newrole-not-suid.patch"
	fi

	if ! use vanilla; then
		# rlpkg is more useful than fixfiles
		sed -i -e '/^all/s/fixfiles//' "${S}/scripts/Makefile" \
			|| die "fixfiles sed 1 failed"
		sed -i -e '/fixfiles/d' "${S}/scripts/Makefile" \
			|| die "fixfiles sed 2 failed"
	fi

	eapply_user

	sed -i 's/-Werror//g' "${S1}"/*/Makefile || die "Failed to remove Werror"

	if ! use vanilla; then
		python_copy_sources
		# Our extra code is outside the regular directory, so set it to the extra
		# directory. We really should optimize this as it is ugly, but the extra
		# code is needed for Gentoo at the same time that policycoreutils is present
		# (so we cannot use an additional package for now).
		S="${S2}"
		python_copy_sources
	fi
}

src_compile() {
	building() {
		local build_dir=${1}
		emake -C "${build_dir}" \
			AUDIT_LOG_PRIVS="y" \
			AUDITH="$(usex audit y n)" \
			PAMH="$(usex pam y n)" \
			SESANDBOX="n" \
			CC="$(tc-getCC)" \
			LIBDIR="\$(PREFIX)/$(get_libdir)"
	}
	if ! use vanilla; then
		building_with_python() {
			building "${BUILD_DIR}"
		}
		S="${S1}" # Regular policycoreutils
		python_foreach_impl building_with_python
		S="${S2}" # Extra set
		python_foreach_impl building_with_python
		unset -f building_with_python
	else
		S="${S1}" # Regular policycoreutils
		building "${S}"
	fi
	unset -f building
}

src_install() {
	installation-policycoreutils-base() {
		local build_dir=${1}
		einfo "Installing policycoreutils"
		emake -C "${build_dir}" DESTDIR="${D}" \
			AUDIT_LOG_PRIVS="y" \
			AUDITH="$(usex audit y n)" \
			PAMH="$(usex pam y n)" \
			SESANDBOX="n" \
			CC="$(tc-getCC)" \
			LIBDIR="\$(PREFIX)/$(get_libdir)" \
			install
	}

	if ! use vanilla; then
		# Python scripts are present in many places. There are no extension modules.
		installation-policycoreutils() {
			installation-policycoreutils-base "${BUILD_DIR}"
			python_optimize
		}

		installation-extras() {
			einfo "Installing policycoreutils-extra"
			emake -C "${BUILD_DIR}" \
				DESTDIR="${D}" \
				install
			python_optimize
		}

		S="${S1}" # policycoreutils
		python_foreach_impl installation-policycoreutils
		S="${S2}" # extras
		python_foreach_impl installation-extras
		S="${S1}" # back for later
		unset -f installation-extras installation-policycoreutils
	else
		S="${S1}" # policycoreutils
		installation-policycoreutils-base "${S}"
	fi
	unset -f installation-policycoreutils-base

	# remove redhat-style init script
	rm -fR "${D}/etc/rc.d" || die

	# compatibility symlinks
	if use split-usr; then
		dosym ../../sbin/setfiles /usr/sbin/setfiles
	else
		# remove sestatus symlink
		rm -f "${D}"/usr/sbin/sestatus || die
	fi

	bashcomp_alias setsebool getsebool

	# location for policy definitions
	dodir /var/lib/selinux
	keepdir /var/lib/selinux

	if ! use vanilla; then
		# Set version-specific scripts
		for pyscript in rlpkg; do
			python_replicate_script "${ED}/usr/sbin/${pyscript}"
		done
	fi
}

pkg_postinst() {
	for POLICY_TYPE in ${POLICY_TYPES} ; do
		# There have been some changes to the policy store, rebuilding now.
		# https://marc.info/?l=selinux&m=143757277819717&w=2
		einfo "Rebuilding store ${POLICY_TYPE} in '${ROOT:-/}' (without re-loading)."
		semodule -p "${ROOT:-/}" -s "${POLICY_TYPE}" -n -B || die "Failed to rebuild policy store ${POLICY_TYPE}"
	done
}
