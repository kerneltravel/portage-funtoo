#!/bin/bash
# Copyright 1999-2012 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2

PORTAGE_BIN_PATH="${PORTAGE_BIN_PATH:-/usr/lib/portage/bin}"
PORTAGE_PYM_PATH="${PORTAGE_PYM_PATH:-/usr/lib/portage/pym}"

# Prevent aliases from causing portage to act inappropriately.
# Make sure it's before everything so we don't mess aliases that follow.
unalias -a

source "${PORTAGE_BIN_PATH}/isolated-functions.sh" || exit 1

if [[ $EBUILD_PHASE != depend ]] ; then
	source "${PORTAGE_BIN_PATH}/phase-functions.sh" || die
	source "${PORTAGE_BIN_PATH}/save-ebuild-env.sh" || die
	source "${PORTAGE_BIN_PATH}/phase-helpers.sh" || die
	source "${PORTAGE_BIN_PATH}/bashrc-functions.sh" || die
else
	# These dummy functions are for things that are likely to be called
	# in global scope, even though they are completely useless during
	# the "depend" phase.
	for x in diropts docompress exeopts get_KV insopts \
		keepdir KV_major KV_micro KV_minor KV_to_int \
		libopts register_die_hook register_success_hook \
		remove_path_entry set_unless_changed strip_duplicate_slashes \
		unset_unless_changed use_with use_enable ; do
		eval "${x}() {
			if has \"\${EAPI:-0}\" 4-python; then
				die \"\${FUNCNAME}() calls are not allowed in global scope\"
			fi
		}"
	done
	# These dummy functions return false in older EAPIs, in order to ensure that
	# `use multislot` is false for the "depend" phase.
	for x in use useq usev ; do
		eval "${x}() {
			if has \"\${EAPI:-0}\" 4-python; then
				die \"\${FUNCNAME}() calls are not allowed in global scope\"
			else
				return 1
			fi
		}"
	done
	# These functions die because calls to them during the "depend" phase
	# are considered to be severe QA violations.
	for x in best_version has_version portageq ; do
		eval "${x}() { die \"\${FUNCNAME}() calls are not allowed in global scope\"; }"
	done
	unset x
fi

# Don't use sandbox's BASH_ENV for new shells because it does
# 'source /etc/profile' which can interfere with the build
# environment by modifying our PATH.
unset BASH_ENV

# This is just a temporary workaround for portage-9999 users since
# earlier portage versions do not detect a version change in this case
# (9999 to 9999) and therefore they try execute an incompatible version of
# ebuild.sh during the upgrade.
export PORTAGE_BZIP2_COMMAND=${PORTAGE_BZIP2_COMMAND:-bzip2} 

# These two functions wrap sourcing and calling respectively.  At present they
# perform a qa check to make sure eclasses and ebuilds and profiles don't mess
# with shell opts (shopts).  Ebuilds/eclasses changing shopts should reset them 
# when they are done.

qa_source() {
	local shopts=$(shopt) OLDIFS="$IFS"
	local retval
	source "$@"
	retval=$?
	set +e
	[[ $shopts != $(shopt) ]] &&
		eqawarn "QA Notice: Global shell options changed and were not restored while sourcing '$*'"
	[[ "$IFS" != "$OLDIFS" ]] &&
		eqawarn "QA Notice: Global IFS changed and was not restored while sourcing '$*'"
	return $retval
}

qa_call() {
	local shopts=$(shopt) OLDIFS="$IFS"
	local retval
	"$@"
	retval=$?
	set +e
	[[ $shopts != $(shopt) ]] &&
		eqawarn "QA Notice: Global shell options changed and were not restored while calling '$*'"
	[[ "$IFS" != "$OLDIFS" ]] &&
		eqawarn "QA Notice: Global IFS changed and was not restored while calling '$*'"
	return $retval
}

EBUILD_SH_ARGS="$*"

shift $#

# Unset some variables that break things.
unset GZIP BZIP BZIP2 CDPATH GREP_OPTIONS GREP_COLOR GLOBIGNORE

[[ $PORTAGE_QUIET != "" ]] && export PORTAGE_QUIET

# sandbox support functions; defined prior to profile.bashrc srcing, since the profile might need to add a default exception (/usr/lib64/conftest fex)
_sb_append_var() {
	local _v=$1 ; shift
	local var="SANDBOX_${_v}"
	[[ -z $1 || -n $2 ]] && die "Usage: add$(echo ${_v} | \
		LC_ALL=C tr [:upper:] [:lower:]) <colon-delimited list of paths>"
	export ${var}="${!var:+${!var}:}$1"
}
# bash-4 version:
# local var="SANDBOX_${1^^}"
# addread() { _sb_append_var ${0#add} "$@" ; }
addread()    { _sb_append_var READ    "$@" ; }
addwrite()   { _sb_append_var WRITE   "$@" ; }
adddeny()    { _sb_append_var DENY    "$@" ; }
addpredict() { _sb_append_var PREDICT "$@" ; }

addwrite "${PORTAGE_TMPDIR}"
addread "/:${PORTAGE_TMPDIR}"
[[ -n ${PORTAGE_GPG_DIR} ]] && addpredict "${PORTAGE_GPG_DIR}"

# Avoid sandbox violations in temporary directories.
if [[ -w $T ]] ; then
	export TEMP=$T
	export TMP=$T
	export TMPDIR=$T
elif [[ $SANDBOX_ON = 1 ]] ; then
	for x in TEMP TMP TMPDIR ; do
		[[ -n ${!x} ]] && addwrite "${!x}"
	done
	unset x
fi

# the sandbox is disabled by default except when overridden in the relevant stages
export SANDBOX_ON=0

esyslog() {
	# Custom version of esyslog() to take care of the "Red Star" bug.
	# MUST follow functions.sh to override the "" parameter problem.
	return 0
}

# Ensure that $PWD is sane whenever possible, to protect against
# exploitation of insecure search path for python -c in ebuilds.
# See bug #239560.
if ! has "$EBUILD_PHASE" clean cleanrm depend help ; then
	cd "$PORTAGE_BUILDDIR" || \
		die "PORTAGE_BUILDDIR does not exist: '$PORTAGE_BUILDDIR'"
fi

#if no perms are specified, dirs/files will have decent defaults
#(not secretive, but not stupid)
umask 022

# debug-print() gets called from many places with verbose status information useful
# for tracking down problems. The output is in $T/eclass-debug.log.
# You can set ECLASS_DEBUG_OUTPUT to redirect the output somewhere else as well.
# The special "on" setting echoes the information, mixing it with the rest of the
# emerge output.
# You can override the setting by exporting a new one from the console, or you can
# set a new default in make.*. Here the default is "" or unset.

# in the future might use e* from /etc/init.d/functions.sh if i feel like it
debug-print() {
	# if $T isn't defined, we're in dep calculation mode and
	# shouldn't do anything
	[[ $EBUILD_PHASE = depend || ! -d ${T} || ${#} -eq 0 ]] && return 0

	if [[ ${ECLASS_DEBUG_OUTPUT} == on ]]; then
		printf 'debug: %s\n' "${@}" >&2
	elif [[ -n ${ECLASS_DEBUG_OUTPUT} ]]; then
		printf 'debug: %s\n' "${@}" >> "${ECLASS_DEBUG_OUTPUT}"
	fi

	if [[ -w $T ]] ; then
		# default target
		printf '%s\n' "${@}" >> "${T}/eclass-debug.log"
		# let the portage user own/write to this file
		chgrp portage "${T}/eclass-debug.log" &>/dev/null
		chmod g+w "${T}/eclass-debug.log" &>/dev/null
	fi
}

# The following 2 functions are debug-print() wrappers

debug-print-function() {
	debug-print "${1}: entering function, parameters: ${*:2}"
}

debug-print-section() {
	debug-print "now in section ${*}"
}

# Sources all eclasses in parameters
declare -ix ECLASS_DEPTH=0
inherit() {
	ECLASS_DEPTH=$(($ECLASS_DEPTH + 1))
	if [[ ${ECLASS_DEPTH} > 1 ]]; then
		debug-print "*** Multiple Inheritence (Level: ${ECLASS_DEPTH})"
	fi

	if [[ -n $ECLASS && -n ${!__export_funcs_var} ]] ; then
		echo "QA Notice: EXPORT_FUNCTIONS is called before inherit in" \
			"$ECLASS.eclass. For compatibility with <=portage-2.1.6.7," \
			"only call EXPORT_FUNCTIONS after inherit(s)." \
			| fmt -w 75 | while read -r ; do eqawarn "$REPLY" ; done
	fi

	local location
	local olocation
	local x

	# These variables must be restored before returning.
	local PECLASS=$ECLASS
	local prev_export_funcs_var=$__export_funcs_var

	local B_IUSE
	local B_REQUIRED_USE
	local B_DEPEND
	local B_RDEPEND
	local B_PDEPEND
	while [ "$1" ]; do
		location="${ECLASSDIR}/${1}.eclass"
		olocation=""

		export ECLASS="$1"
		__export_funcs_var=__export_functions_$ECLASS_DEPTH
		unset $__export_funcs_var

		if [ "${EBUILD_PHASE}" != "depend" ] && \
			[ "${EBUILD_PHASE}" != "nofetch" ] && \
			[[ ${EBUILD_PHASE} != *rm ]] && \
			[[ ${EMERGE_FROM} != "binary" ]] ; then
			# This is disabled in the *rm phases because they frequently give
			# false alarms due to INHERITED in /var/db/pkg being outdated
			# in comparison the the eclasses from the portage tree. It's
			# disabled for nofetch, since that can be called by repoman and
			# that triggers bug #407449 due to repoman not exporting
			# non-essential variables such as INHERITED.
			if ! has $ECLASS $INHERITED $__INHERITED_QA_CACHE ; then
				eqawarn "QA Notice: ECLASS '$ECLASS' inherited illegally in $CATEGORY/$PF $EBUILD_PHASE"
			fi
		fi

		# any future resolution code goes here
		if [ -n "$PORTDIR_OVERLAY" ]; then
			local overlay
			for overlay in ${PORTDIR_OVERLAY}; do
				olocation="${overlay}/eclass/${1}.eclass"
				if [ -e "$olocation" ]; then
					location="${olocation}"
					debug-print "  eclass exists: ${location}"
				fi
			done
		fi
		debug-print "inherit: $1 -> $location"
		[ ! -e "$location" ] && die "${1}.eclass could not be found by inherit()"

		if [ "${location}" == "${olocation}" ] && \
			! has "${location}" ${EBUILD_OVERLAY_ECLASSES} ; then
				EBUILD_OVERLAY_ECLASSES="${EBUILD_OVERLAY_ECLASSES} ${location}"
		fi

		#We need to back up the value of DEPEND and RDEPEND to B_DEPEND and B_RDEPEND
		#(if set).. and then restore them after the inherit call.

		#turn off glob expansion
		set -f

		# Retain the old data and restore it later.
		unset B_IUSE B_REQUIRED_USE B_DEPEND B_RDEPEND B_PDEPEND
		[ "${IUSE+set}"       = set ] && B_IUSE="${IUSE}"
		[ "${REQUIRED_USE+set}" = set ] && B_REQUIRED_USE="${REQUIRED_USE}"
		[ "${DEPEND+set}"     = set ] && B_DEPEND="${DEPEND}"
		[ "${RDEPEND+set}"    = set ] && B_RDEPEND="${RDEPEND}"
		[ "${PDEPEND+set}"    = set ] && B_PDEPEND="${PDEPEND}"
		unset IUSE REQUIRED_USE DEPEND RDEPEND PDEPEND
		#turn on glob expansion
		set +f

		qa_source "$location" || die "died sourcing $location in inherit()"
		
		#turn off glob expansion
		set -f

		# If each var has a value, append it to the global variable E_* to
		# be applied after everything is finished. New incremental behavior.
		[ "${IUSE+set}"         = set ] && E_IUSE+="${E_IUSE:+ }${IUSE}"
		[ "${REQUIRED_USE+set}" = set ] && E_REQUIRED_USE+="${E_REQUIRED_USE:+ }${REQUIRED_USE}"
		[ "${DEPEND+set}"       = set ] && E_DEPEND+="${E_DEPEND:+ }${DEPEND}"
		[ "${RDEPEND+set}"      = set ] && E_RDEPEND+="${E_RDEPEND:+ }${RDEPEND}"
		[ "${PDEPEND+set}"      = set ] && E_PDEPEND+="${E_PDEPEND:+ }${PDEPEND}"

		[ "${B_IUSE+set}"     = set ] && IUSE="${B_IUSE}"
		[ "${B_IUSE+set}"     = set ] || unset IUSE
		
		[ "${B_REQUIRED_USE+set}"     = set ] && REQUIRED_USE="${B_REQUIRED_USE}"
		[ "${B_REQUIRED_USE+set}"     = set ] || unset REQUIRED_USE

		[ "${B_DEPEND+set}"   = set ] && DEPEND="${B_DEPEND}"
		[ "${B_DEPEND+set}"   = set ] || unset DEPEND

		[ "${B_RDEPEND+set}"  = set ] && RDEPEND="${B_RDEPEND}"
		[ "${B_RDEPEND+set}"  = set ] || unset RDEPEND

		[ "${B_PDEPEND+set}"  = set ] && PDEPEND="${B_PDEPEND}"
		[ "${B_PDEPEND+set}"  = set ] || unset PDEPEND

		#turn on glob expansion
		set +f

		if [[ -n ${!__export_funcs_var} ]] ; then
			for x in ${!__export_funcs_var} ; do
				debug-print "EXPORT_FUNCTIONS: $x -> ${ECLASS}_$x"
				declare -F "${ECLASS}_$x" >/dev/null || \
					die "EXPORT_FUNCTIONS: ${ECLASS}_$x is not defined"
				eval "$x() { ${ECLASS}_$x \"\$@\" ; }" > /dev/null
			done
		fi
		unset $__export_funcs_var

		has $1 $INHERITED || export INHERITED="$INHERITED $1"

		shift
	done
	((--ECLASS_DEPTH)) # Returns 1 when ECLASS_DEPTH reaches 0.
	if (( ECLASS_DEPTH > 0 )) ; then
		export ECLASS=$PECLASS
		__export_funcs_var=$prev_export_funcs_var
	else
		unset ECLASS __export_funcs_var
	fi
	return 0
}

# Exports stub functions that call the eclass's functions, thereby making them default.
# For example, if ECLASS="base" and you call "EXPORT_FUNCTIONS src_unpack", the following
# code will be eval'd:
# src_unpack() { base_src_unpack; }
EXPORT_FUNCTIONS() {
	if [ -z "$ECLASS" ]; then
		die "EXPORT_FUNCTIONS without a defined ECLASS"
	fi
	eval $__export_funcs_var+=\" $*\"
}

PORTAGE_BASHRCS_SOURCED=0

# @FUNCTION: source_all_bashrcs
# @DESCRIPTION:
# Source a relevant bashrc files and perform other miscellaneous
# environment initialization when appropriate.
#
# If EAPI is set then define functions provided by the current EAPI:
#
#  * default_* aliases for the current EAPI phase functions
#  * A "default" function which is an alias for the default phase
#    function for the current phase.
#
source_all_bashrcs() {
	[[ $PORTAGE_BASHRCS_SOURCED = 1 ]] && return 0
	PORTAGE_BASHRCS_SOURCED=1
	local x

	local OCC="${CC}" OCXX="${CXX}"

	if [[ $EBUILD_PHASE != depend ]] ; then
		# source the existing profile.bashrcs.
		save_IFS
		IFS=$'\n'
		local path_array=($PROFILE_PATHS)
		restore_IFS
		for x in "${path_array[@]}" ; do
			[ -f "$x/profile.bashrc" ] && qa_source "$x/profile.bashrc"
		done

		# The user's bashrc is the ONLY non-portage bit of code that can
		# change shopts without a QA violation.
		for x in "${PM_EBUILD_HOOK_DIR}"/${CATEGORY}/{${PN},${PN}:${SLOT},${P},${PF}}; do
			if [ -r "${x}" ] && [ ! -d "${x}" ]; then
				# If $- contains x, then tracing has already been enabled
				# elsewhere for some reason. We preserve it's state so as
				# not to interfere.
				if [ "$PORTAGE_DEBUG" != "1" ] || [ "${-/x/}" != "$-" ]; then
					source "${x}"
				else
					set -x
					source "${x}"
					set +x
				fi
			fi
		done
	fi

	if [ -r "${PORTAGE_BASHRC}" ] ; then
		if [ "$PORTAGE_DEBUG" != "1" ] || [ "${-/x/}" != "$-" ]; then
			source "${PORTAGE_BASHRC}"
		else
			set -x
			source "${PORTAGE_BASHRC}"
			set +x
		fi
	fi

	[ ! -z "${OCC}" ] && export CC="${OCC}"
	[ ! -z "${OCXX}" ] && export CXX="${OCXX}"
}

# === === === === === === === === === === === === === === === === === ===
# === === === === === functions end, main part begins === === === === ===
# === === === === === === === === === === === === === === === === === ===

export SANDBOX_ON="1"
export S=${WORKDIR}/${P}

# Turn of extended glob matching so that g++ doesn't get incorrectly matched.
shopt -u extglob

if [[ ${EBUILD_PHASE} == depend ]] ; then
	QA_INTERCEPTORS="awk bash cc egrep equery fgrep g++
		gawk gcc grep javac java-config nawk perl
		pkg-config python python-config sed"
elif [[ ${EBUILD_PHASE} == clean* ]] ; then
	unset QA_INTERCEPTORS
else
	QA_INTERCEPTORS="autoconf automake aclocal libtoolize"
fi
# level the QA interceptors if we're in depend
if [[ -n ${QA_INTERCEPTORS} ]] ; then
	for BIN in ${QA_INTERCEPTORS}; do
		BIN_PATH=$(type -Pf ${BIN})
		if [ "$?" != "0" ]; then
			BODY="echo \"*** missing command: ${BIN}\" >&2; return 127"
		else
			BODY="${BIN_PATH} \"\$@\"; return \$?"
		fi
		if [[ ${EBUILD_PHASE} == depend ]] ; then
			FUNC_SRC="${BIN}() {
				if [ \$ECLASS_DEPTH -gt 0 ]; then
					eqawarn \"QA Notice: '${BIN}' called in global scope: eclass \${ECLASS}\"
				else
					eqawarn \"QA Notice: '${BIN}' called in global scope: \${CATEGORY}/\${PF}\"
				fi
			${BODY}
			}"
		elif has ${BIN} autoconf automake aclocal libtoolize ; then
			FUNC_SRC="${BIN}() {
				if ! has \${FUNCNAME[1]} eautoreconf eaclocal _elibtoolize \\
					eautoheader eautoconf eautomake autotools_run_tool \\
					autotools_check_macro autotools_get_subdirs \\
					autotools_get_auxdir ; then
					eqawarn \"QA Notice: '${BIN}' called by \${FUNCNAME[1]}: \${CATEGORY}/\${PF}\"
					eqawarn \"Use autotools.eclass instead of calling '${BIN}' directly.\"
				fi
			${BODY}
			}"
		else
			FUNC_SRC="${BIN}() {
				eqawarn \"QA Notice: '${BIN}' called by \${FUNCNAME[1]}: \${CATEGORY}/\${PF}\"
			${BODY}
			}"
		fi
		eval "$FUNC_SRC" || echo "error creating QA interceptor ${BIN}" >&2
	done
	unset BIN_PATH BIN BODY FUNC_SRC
fi

# Subshell/helper die support (must export for the die helper).
export EBUILD_MASTER_PID=$BASHPID
trap 'exit 1' SIGTERM

if ! has "$EBUILD_PHASE" clean cleanrm depend && \
	[ -f "${T}"/environment ] ; then
	# The environment may have been extracted from environment.bz2 or
	# may have come from another version of ebuild.sh or something.
	# In any case, preprocess it to prevent any potential interference.
	# NOTE: export ${FOO}=... requires quoting, unlike normal exports
	preprocess_ebuild_env || \
		die "error processing environment"
	# Colon separated SANDBOX_* variables need to be cumulative.
	for x in SANDBOX_DENY SANDBOX_READ SANDBOX_PREDICT SANDBOX_WRITE ; do
		export PORTAGE_${x}="${!x}"
	done
	PORTAGE_SANDBOX_ON=${SANDBOX_ON}
	export SANDBOX_ON=1
	source "${T}"/environment || \
		die "error sourcing environment"
	# We have to temporarily disable sandbox since the
	# SANDBOX_{DENY,READ,PREDICT,WRITE} values we've just loaded
	# may be unusable (triggering in spurious sandbox violations)
	# until we've merged them with our current values.
	export SANDBOX_ON=0
	for x in SANDBOX_DENY SANDBOX_PREDICT SANDBOX_READ SANDBOX_WRITE ; do
		y="PORTAGE_${x}"
		if [ -z "${!x}" ] ; then
			export ${x}="${!y}"
		elif [ -n "${!y}" ] && [ "${!y}" != "${!x}" ] ; then
			# filter out dupes
			export ${x}="$(printf "${!y}:${!x}" | tr ":" "\0" | \
				sort -z -u | tr "\0" ":")"
		fi
		export ${x}="${!x%:}"
		unset PORTAGE_${x}
	done
	unset x y
	export SANDBOX_ON=${PORTAGE_SANDBOX_ON}
	unset PORTAGE_SANDBOX_ON
	[[ -n $EAPI ]] || EAPI=0
fi

if ! has "$EBUILD_PHASE" clean cleanrm ; then
	if [[ $EBUILD_PHASE = depend || ! -f $T/environment || \
		-f $PORTAGE_BUILDDIR/.ebuild_changed ]] || \
		has noauto $FEATURES ; then
		# The bashrcs get an opportunity here to set aliases that will be expanded
		# during sourcing of ebuilds and eclasses.
		source_all_bashrcs

		# When EBUILD_PHASE != depend, INHERITED comes pre-initialized
		# from cache. In order to make INHERITED content independent of
		# EBUILD_PHASE during inherit() calls, we unset INHERITED after
		# we make a backup copy for QA checks.
		__INHERITED_QA_CACHE=$INHERITED

		# *DEPEND and IUSE will be set during the sourcing of the ebuild.
		# In order to ensure correct interaction between ebuilds and
		# eclasses, they need to be unset before this process of
		# interaction begins.
		unset DEPEND RDEPEND PDEPEND INHERITED IUSE REQUIRED_USE \
			ECLASS E_IUSE E_REQUIRED_USE E_DEPEND E_RDEPEND E_PDEPEND

		if [[ $PORTAGE_DEBUG != 1 || ${-/x/} != $- ]] ; then
			source "$EBUILD" || die "error sourcing ebuild"
		else
			set -x
			source "$EBUILD" || die "error sourcing ebuild"
			set +x
		fi

		if [[ "${EBUILD_PHASE}" != "depend" ]] ; then
			RESTRICT=${PORTAGE_RESTRICT}
			[[ -e $PORTAGE_BUILDDIR/.ebuild_changed ]] && \
			rm "$PORTAGE_BUILDDIR/.ebuild_changed"
		fi

		[[ -n $EAPI ]] || EAPI=0

		if has "$EAPI" 0 1 2 3 3_pre2 ; then
			export RDEPEND=${RDEPEND-${DEPEND}}
			debug-print "RDEPEND: not set... Setting to: ${DEPEND}"
		fi

		# add in dependency info from eclasses
		IUSE+="${IUSE:+ }${E_IUSE}"
		DEPEND+="${DEPEND:+ }${E_DEPEND}"
		RDEPEND+="${RDEPEND:+ }${E_RDEPEND}"
		PDEPEND+="${PDEPEND:+ }${E_PDEPEND}"
		REQUIRED_USE+="${REQUIRED_USE:+ }${E_REQUIRED_USE}"
		
		unset ECLASS E_IUSE E_REQUIRED_USE E_DEPEND E_RDEPEND E_PDEPEND \
			__INHERITED_QA_CACHE

		# alphabetically ordered by $EBUILD_PHASE value
		case "$EAPI" in
			0|1)
				_valid_phases="src_compile pkg_config pkg_info src_install
					pkg_nofetch pkg_postinst pkg_postrm pkg_preinst pkg_prerm
					pkg_setup src_test src_unpack"
				;;
			2|3|3_pre2)
				_valid_phases="src_compile pkg_config src_configure pkg_info
					src_install pkg_nofetch pkg_postinst pkg_postrm pkg_preinst
					src_prepare pkg_prerm pkg_setup src_test src_unpack"
				;;
			*)
				_valid_phases="src_compile pkg_config src_configure pkg_info
					src_install pkg_nofetch pkg_postinst pkg_postrm pkg_preinst
					src_prepare pkg_prerm pkg_pretend pkg_setup src_test src_unpack"
				;;
		esac

		DEFINED_PHASES=
		for _f in $_valid_phases ; do
			if declare -F $_f >/dev/null ; then
				_f=${_f#pkg_}
				DEFINED_PHASES+=" ${_f#src_}"
			fi
		done
		[[ -n $DEFINED_PHASES ]] || DEFINED_PHASES=-

		unset _f _valid_phases

		if [[ $EBUILD_PHASE != depend ]] ; then

			if has distcc $FEATURES ; then
				[[ -n $DISTCC_LOG ]] && addwrite "${DISTCC_LOG%/*}"
			fi

			if has ccache $FEATURES ; then

				if [[ -n $CCACHE_DIR ]] ; then
					addread "$CCACHE_DIR"
					addwrite "$CCACHE_DIR"
				fi

				[[ -n $CCACHE_SIZE ]] && ccache -M $CCACHE_SIZE &> /dev/null
			fi

			if [[ -n $QA_PREBUILT ]] ; then

				# these ones support fnmatch patterns
				QA_EXECSTACK+=" $QA_PREBUILT"
				QA_TEXTRELS+=" $QA_PREBUILT"
				QA_WX_LOAD+=" $QA_PREBUILT"

				# these ones support regular expressions, so translate
				# fnmatch patterns to regular expressions
				for x in QA_DT_NEEDED QA_FLAGS_IGNORED QA_PRESTRIPPED QA_SONAME ; do
					if [[ $(declare -p $x 2>/dev/null) = declare\ -a* ]] ; then
						eval "$x=(\"\${$x[@]}\" ${QA_PREBUILT//\*/.*})"
					else
						eval "$x+=\" ${QA_PREBUILT//\*/.*}\""
					fi
				done

				unset x
			fi

			# This needs to be exported since prepstrip is a separate shell script.
			[[ -n $QA_PRESTRIPPED ]] && export QA_PRESTRIPPED
			eval "[[ -n \$QA_PRESTRIPPED_${ARCH/-/_} ]] && \
				export QA_PRESTRIPPED_${ARCH/-/_}"
		fi
	fi
fi

# unset USE_EXPAND variables that contain only the special "*" token
for x in ${USE_EXPAND} ; do
	[ "${!x}" == "*" ] && unset ${x}
done
unset x

if has nostrip ${FEATURES} ${RESTRICT} || has strip ${RESTRICT}
then
	export DEBUGBUILD=1
fi

if [[ $EBUILD_PHASE = depend ]] ; then
	export SANDBOX_ON="0"
	set -f

	if [ -n "${dbkey}" ] ; then
		if [ ! -d "${dbkey%/*}" ]; then
			install -d -g ${PORTAGE_GID} -m2775 "${dbkey%/*}"
		fi
		# Make it group writable. 666&~002==664
		umask 002
	fi

	auxdbkeys="DEPEND RDEPEND SLOT SRC_URI RESTRICT HOMEPAGE LICENSE
		DESCRIPTION KEYWORDS INHERITED IUSE REQUIRED_USE PDEPEND PROVIDE EAPI
		PROPERTIES DEFINED_PHASES UNUSED_05 UNUSED_04
		UNUSED_03 UNUSED_02 UNUSED_01"

	[ -n "${EAPI}" ] || EAPI=0

	# The extra $(echo) commands remove newlines.
	if [ -n "${dbkey}" ] ; then
		> "${dbkey}"
		for f in ${auxdbkeys} ; do
			echo $(echo ${!f}) >> "${dbkey}" || exit $?
		done
	else
		for f in ${auxdbkeys} ; do
			echo $(echo ${!f}) 1>&9 || exit $?
		done
		exec 9>&-
	fi
	set +f
else
	# Note: readonly variables interfere with preprocess_ebuild_env(), so
	# declare them only after it has already run.
	declare -r $PORTAGE_READONLY_METADATA $PORTAGE_READONLY_VARS
	case "$EAPI" in
		0|1|2)
			[[ " ${FEATURES} " == *" force-prefix "* ]] && \
				declare -r ED EPREFIX EROOT
			;;
		*)
			declare -r ED EPREFIX EROOT
			;;
	esac

	if [[ -n $EBUILD_SH_ARGS ]] ; then
		(
			# Don't allow subprocesses to inherit the pipe which
			# emerge uses to monitor ebuild.sh.
			exec 9>&-
			ebuild_main ${EBUILD_SH_ARGS}
			exit 0
		)
		exit $?
	fi
fi

# Do not exit when ebuild.sh is sourced by other scripts.
true
