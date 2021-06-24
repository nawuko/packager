#!/usr/bin/env bash

# release.sh generates an addon zip file from a Git, SVN, or Mercurial checkout.
#
# This is free and unencumbered software released into the public domain.
#
# Anyone is free to copy, modify, publish, use, compile, sell, or
# distribute this software, either in source code form or as a compiled
# binary, for any purpose, commercial or non-commercial, and by any
# means.
#
# In jurisdictions that recognize copyright laws, the author or authors
# of this software dedicate any and all copyright interest in the
# software to the public domain. We make this dedication for the benefit
# of the public at large and to the detriment of our heirs and
# successors. We intend this dedication to be an overt act of
# relinquishment in perpetuity of all present and future rights to this
# software under copyright law.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
# IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR
# OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
# ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.
#
# For more information, please refer to <http://unlicense.org/>

## USER OPTIONS

# Secrets for uploading
github_token=
wago_token=

# Variables set via command-line options
wagoid=
topdir=
releasedir=
overwrite=
nolib=
line_ending="dos"
skip_copying=
skip_zipfile=
skip_upload=
pkgmeta_file=

# Game versions for uploading
game_version=
game_version_id=
toc_version=
alpha=
classic=

## END USER OPTIONS


# Script return code
exit_code=0

# Process command-line options
usage() {
	echo "Usage: release.sh [-cdelLosuz] [-t topdir] [-r releasedir] [-p curse-id] [-w wowi-id] [-g game-version] [-m pkgmeta.yml]" >&2
	echo "  -c               Skip copying files into the package directory." >&2
	echo "  -d               Skip uploading." >&2
	echo "  -o               Keep existing package directory, overwriting its contents." >&2
	echo "  -s               Create a stripped-down \"nolib\" package." >&2
	echo "  -u               Use Unix line-endings." >&2
	echo "  -z               Skip zip file creation." >&2
	echo "  -t topdir        Set top-level directory of checkout." >&2
	echo "  -r releasedir    Set directory containing the package directory. Defaults to \"\$topdir/.release\"." >&2
	echo "  -g game-version  Set the game version to use for CurseForge uploading." >&2
	echo "  -m pkgmeta.yaml  Set the pkgmeta file to use." >&2
}

OPTIND=1
while getopts ":celLzusop:dw:a:r:t:g:m:" opt; do
	case $opt in
	c)
		# Skip copying files into the package directory.
		skip_copying="true"
		skip_upload="true"
		;;
	a) wagoid="$OPTARG" ;; # Set Wago Addons project id
	d)
		# Skip uploading.
		skip_upload="true"
		;;
	o)
		# Skip deleting any previous package directory.
		overwrite="true"
		;;
	r)
		# Set the release directory to a non-default value.
		releasedir="$OPTARG"
		;;
	s)
		# Create a nolib package.
		nolib="true"
		;;
	t)
		# Set the top-level directory of the checkout to a non-default value.
		if [ ! -d "$OPTARG" ]; then
			echo "Invalid argument for option \"-t\" - Directory \"$OPTARG\" does not exist." >&2
			usage
			exit 1
		fi
		topdir="$OPTARG"
		;;
	u)
		# Skip Unix-to-DOS line-ending translation.
		line_ending=unix
		;;
	z)
		# Skip generating the zipfile.
		skip_zipfile="true"
		;;
	g)
		# shortcut for classic
		if [ "$OPTARG" = "classic" ]; then
			classic="true"
			# game_version from toc
		else
			# Set version (x.y.z)
			IFS=',' read -ra V <<< "$OPTARG"
			for i in "${V[@]}"; do
				if [[ ! "$i" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)[a-z]?$ ]]; then
					echo "Invalid argument for option \"-g\" ($i)" >&2
					usage
					exit 1
				fi
				if [[ ${BASH_REMATCH[1]} == "1" && ${BASH_REMATCH[2]} == "13" ]]; then
					classic="true"
					toc_version=$( printf "%d%02d%02d" ${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[3]} )
				fi
			done
			game_version="$OPTARG"
		fi
		;;
	m)
		# Set the pkgmeta file.
		if [ ! -f "$OPTARG" ]; then
			echo "Invalid argument for option \"-m\" - File \"$OPTARG\" does not exist." >&2
			usage
			exit 1
		fi
		pkgmeta_file="$OPTARG"
		;;
	:)
		echo "Option \"-$OPTARG\" requires an argument." >&2
		usage
		exit 1
		;;
	\?)
		if [ "$OPTARG" = "?" ] || [ "$OPTARG" = "h" ]; then
			usage
			exit 0
		fi
		echo "Unknown option \"-$OPTARG\"" >&2
		usage
		exit 1
		;;
	esac
done
shift $((OPTIND - 1))

# Set $topdir to top-level directory of the checkout.
if [ -z "$topdir" ]; then
	dir=$( pwd )
	if [ -d "$dir/.git" ] || [ -d "$dir/.svn" ] || [ -d "$dir/.hg" ]; then
		topdir=.
	else
		dir=${dir%/*}
		topdir=".."
		while [ -n "$dir" ]; do
			if [ -d "$topdir/.git" ] || [ -d "$topdir/.svn" ] || [ -d "$topdir/.hg" ]; then
				break
			fi
			dir=${dir%/*}
			topdir="$topdir/.."
		done
		if [ ! -d "$topdir/.git" ] && [ ! -d "$topdir/.svn" ] && [ ! -d "$topdir/.hg" ]; then
			echo "No Git, SVN, or Hg checkout found." >&2
			exit 1
		fi
	fi
fi

# Handle folding sections in CI logs
start_group() { echo "$1"; }
end_group() { echo; }

# Check for Travis CI
if [ -n "$TRAVIS" ]; then
	# Don't run the packager for pull requests
	if [ "$TRAVIS_PULL_REQUEST" != "false" ]; then
		echo "Not packaging pull request."
		exit 0
	fi
	if [ -z "$TRAVIS_TAG" ]; then
		# Don't run the packager if there is a tag pending
		check_tag=$( git -C "$topdir" tag --points-at HEAD )
		if [ -n "$check_tag" ]; then
			echo "Found future tag \"${check_tag}\", not packaging."
			exit 0
		fi
		# Only package master, classic, or develop
		if [ "$TRAVIS_BRANCH" != "master" ] && [ "$TRAVIS_BRANCH" != "classic" ] && [ "$TRAVIS_BRANCH" != "develop" ]; then
			echo "Not packaging \"${TRAVIS_BRANCH}\"."
			exit 0
		fi
	fi
	# https://github.com/travis-ci/travis-build/tree/master/lib/travis/build/bash
	start_group() {
		echo -en "travis_fold:start:$2\\r\033[0K"
		# release_timer_id="$(printf %08x $((RANDOM * RANDOM)))"
		# release_timer_start_time="$(date -u +%s%N)"
		# echo -en "travis_time:start:${release_timer_id}\\r\033[0K"
		echo "$1"
	}
	end_group() {
		# local release_timer_end_time="$(date -u +%s%N)"
		# local duration=$((release_timer_end_time - release_timer_start_time))
		# echo -en "\\ntravis_time:end:${release_timer_id}:start=${release_timer_start_time},finish=${release_timer_end_time},duration=${duration}\\r\033[0K"
		echo -en "travis_fold:end:$1\\r\033[0K"
	}
fi

# Check for GitHub Actions
if [ -n "$GITHUB_ACTIONS" ]; then
	# Prevent duplicate builds
	if [[ "$GITHUB_REF" == "refs/heads"* ]]; then
		check_tag=$( git -C "$topdir" tag --points-at HEAD )
		if [ -n "$check_tag" ]; then
			echo "Found future tag \"${check_tag}\", not packaging."
			exit 0
		fi
	fi
	start_group() { echo "##[group]$1"; }
	end_group() { echo "##[endgroup]"; }
fi
unset check_tag

# Load secrets
if [ -f "$topdir/.env" ]; then
	# shellcheck disable=1090
	. "$topdir/.env"
elif [ -f ".env" ]; then
	. ".env"
fi

[ -z "$github_token" ] && github_token=$GITHUB_OAUTH
[ -z "$wago_token" ] && wago_token=$WAGO_API_TOKEN

# Set $releasedir to the directory which will contain the generated addon zipfile.
if [ -z "$releasedir" ]; then
	releasedir="$topdir/.release"
fi

# Set $basedir to the basename of the checkout directory.
basedir=$( cd "$topdir" && pwd )
case $basedir in
/*/*)
	basedir=${basedir##/*/}
	;;
/*)
	basedir=${basedir##/}
	;;
esac

# Set $repository_type to "git" or "svn" or "hg".
repository_type=
if [ -d "$topdir/.git" ]; then
	repository_type=git
else
	echo "No Git checkout found in \"$topdir\"." >&2
	exit 1
fi

# $releasedir must be an absolute path or inside $topdir.
case $releasedir in
/*)			;;
$topdir/*)	;;
*)
	echo "The release directory \"$releasedir\" must be an absolute path or inside \"$topdir\"." >&2
	exit 1
	;;
esac

# Create the staging directory.
mkdir -p "$releasedir" 2>/dev/null || {
	echo "Unable to create the release directory \"$releasedir\"." >&2
	exit 1
}

# Expand $topdir and $releasedir to their absolute paths for string comparisons later.
topdir=$( cd "$topdir" && pwd )
releasedir=$( cd "$releasedir" && pwd )

###
### set_info_<repo> returns the following information:
###
si_repo_type= # "git"
si_repo_dir= # the checkout directory
si_repo_url= # the checkout url
si_tag= # tag for HEAD
si_previous_tag= # previous tag

si_project_revision= # Turns into the highest revision of the entire project in integer form, e.g. 1234, for SVN. Turns into the commit count for the project's hash for Git.
si_project_hash= # [Git|Hg] Turns into the hash of the entire project in hex form. e.g. 106c634df4b3dd4691bf24e148a23e9af35165ea
si_project_abbreviated_hash= # [Git|Hg] Turns into the abbreviated hash of the entire project in hex form. e.g. 106c63f
si_project_author= # Turns into the last author of the entire project. e.g. ckknight
si_project_date_iso= # Turns into the last changed date (by UTC) of the entire project in ISO 8601. e.g. 2008-05-01T12:34:56Z
si_project_date_integer= # Turns into the last changed date (by UTC) of the entire project in a readable integer fashion. e.g. 2008050123456
si_project_timestamp= # Turns into the last changed date (by UTC) of the entire project in POSIX timestamp. e.g. 1209663296
si_project_version= # Turns into an approximate version of the project. The tag name if on a tag, otherwise it's up to the repo. SVN returns something like "r1234", Git returns something like "v0.1-873fc1"

si_file_revision= # Turns into the current revision of the file in integer form, e.g. 1234, for SVN. Turns into the commit count for the file's hash for Git.
si_file_hash= # Turns into the hash of the file in hex form. e.g. 106c634df4b3dd4691bf24e148a23e9af35165ea
si_file_abbreviated_hash= # Turns into the abbreviated hash of the file in hex form. e.g. 106c63
si_file_author= # Turns into the last author of the file. e.g. ckknight
si_file_date_iso= # Turns into the last changed date (by UTC) of the file in ISO 8601. e.g. 2008-05-01T12:34:56Z
si_file_date_integer= # Turns into the last changed date (by UTC) of the file in a readable integer fashion. e.g. 20080501123456
si_file_timestamp= # Turns into the last changed date (by UTC) of the file in POSIX timestamp. e.g. 1209663296

# SVN date helper function
strtotime() {
	local value="$1" # datetime string
	local format="$2" # strptime string
	if [[ "${OSTYPE,,}" == *"darwin"* ]]; then # bsd
		date -j -f "$format" "$value" "+%s" 2>/dev/null
	else # gnu
		date -d "$value" +%s 2>/dev/null
	fi
}

set_info_git() {
	si_repo_dir="$1"
	si_repo_type="git"
	si_repo_url=$( git -C "$si_repo_dir" remote get-url origin 2>/dev/null | sed -e 's/^git@\(.*\):/https:\/\/\1\//' )
	if [ -z "$si_repo_url" ]; then # no origin so grab the first fetch url
		si_repo_url=$( git -C "$si_repo_dir" remote -v | awk '/(fetch)/ { print $2; exit }' | sed -e 's/^git@\(.*\):/https:\/\/\1\//' )
	fi

	# Populate filter vars.
	si_project_hash=$( git -C "$si_repo_dir" show --no-patch --format="%H" 2>/dev/null )
	si_project_abbreviated_hash=$( git -C "$si_repo_dir" show --no-patch --abbrev=7 --format="%h" 2>/dev/null )
	si_project_author=$( git -C "$si_repo_dir" show --no-patch --format="%an" 2>/dev/null )
	si_project_timestamp=$( git -C "$si_repo_dir" show --no-patch --format="%at" 2>/dev/null )
	si_project_date_iso=$( TZ='' printf "%(%Y-%m-%dT%H:%M:%SZ)T" "$si_project_timestamp" )
	si_project_date_integer=$( TZ='' printf "%(%Y%m%d%H%M%S)T" "$si_project_timestamp" )
	# XXX --depth limits rev-list :\ [ ! -s "$(git rev-parse --git-dir)/shallow" ] || git fetch --unshallow --no-tags
	si_project_revision=$( git -C "$si_repo_dir" rev-list --count "$si_project_hash" 2>/dev/null )

	# Get the tag for the HEAD.
	si_previous_tag=
	_si_tag=$( git -C "$si_repo_dir" describe --tags --always --abbrev=7 2>/dev/null )
	si_tag=$( git -C "$si_repo_dir" describe --tags --always --abbrev=0 2>/dev/null )
	# Set $si_project_version to the version number of HEAD. May be empty if there are no commits.
	si_project_version=$si_tag
	# The HEAD is not tagged if the HEAD is several commits past the most recent tag.
	if [ "$si_tag" = "$si_project_hash" ]; then
		# --abbrev=0 expands out the full sha if there was no previous tag
		si_project_version=$_si_tag
		si_previous_tag=
		si_tag=
	elif [ "$_si_tag" != "$si_tag" ]; then
		# not on a tag
		si_project_version=$( git -C "$si_repo_dir" describe --tags --abbrev=7 2>/dev/null )
		si_previous_tag=$( git -C "$si_repo_dir" describe --tags --abbrev=0 2>/dev/null )
		si_tag=
	else # we're on a tag, just jump back one commit
		si_previous_tag=$( git -C "$si_repo_dir" describe --tags --abbrev=0 HEAD~ 2>/dev/null )
	fi
}

set_info_file() {
	if [ "$si_repo_type" = "git" ]; then
		_si_file=${1#si_repo_dir} # need the path relative to the checkout
		# Populate filter vars from the last commit the file was included in.
		si_file_hash=$( git -C "$si_repo_dir" log --max-count=1 --format="%H" "$_si_file" 2>/dev/null )
		si_file_abbreviated_hash=$( git -C "$si_repo_dir" log --max-count=1 --abbrev=7 --format="%h" "$_si_file" 2>/dev/null )
		si_file_author=$( git -C "$si_repo_dir" log --max-count=1 --format="%an" "$_si_file" 2>/dev/null )
		si_file_timestamp=$( git -C "$si_repo_dir" log --max-count=1 --format="%at" "$_si_file" 2>/dev/null )
		si_file_date_iso=$( TZ='' printf "%(%Y-%m-%dT%H:%M:%SZ)T" "$si_file_timestamp" )
		si_file_date_integer=$( TZ='' printf "%(%Y%m%d%H%M%S)T" "$si_file_timestamp" )
		si_file_revision=$( git -C "$si_repo_dir" rev-list --count "$si_file_hash" 2>/dev/null ) # XXX checkout depth affects rev-list, see set_info_git
	fi
}

# Set some version info about the project
case $repository_type in
git)	set_info_git "$topdir" ;;
esac

tag=$si_tag
[[ -z "$tag" || "${tag,,}" == *"alpha"* ]] && alpha="true"
[[ -z "$tag" || "${tag,,}" == *"beta"* ]] && alpha="true"
project_version=$si_project_version
previous_version=$si_previous_tag
project_hash=$si_project_hash
project_revision=$si_project_revision
project_timestamp=$si_project_timestamp
project_github_url=
project_github_slug=
if [[ "$si_repo_url" == "https://github.com"* ]]; then
	project_github_url=${si_repo_url%.git}
	project_github_slug=${project_github_url#https://github.com/}
fi
project_site=

# Bare carriage-return character.
carriage_return=$( printf "\r" )

# Returns 0 if $1 matches one of the colon-separated patterns in $2.
match_pattern() {
	_mp_file=$1
	_mp_list="$2:"
	while [ -n "$_mp_list" ]; do
		_mp_pattern=${_mp_list%%:*}
		_mp_list=${_mp_list#*:}
		# shellcheck disable=2254
		case $_mp_file in
			$_mp_pattern)
				return 0
				;;
		esac
	done
	return 1
}

# Simple .pkgmeta YAML processor.
yaml_keyvalue() {
	yaml_key=${1%%:*}
	yaml_value=${1#$yaml_key:}
	yaml_value=${yaml_value#"${yaml_value%%[! ]*}"} # trim leading whitespace
	yaml_value=${yaml_value#[\'\"]} # trim leading quotes
	yaml_value=${yaml_value%[\'\"]} # trim trailing quotes
}

yaml_listitem() {
	yaml_item=${1#-}
	yaml_item=${yaml_item#"${yaml_item%%[! ]*}"} # trim leading whitespace
}

###
### Process .pkgmeta to set variables used later in the script.
###

if [ -z "$pkgmeta_file" ]; then
	pkgmeta_file="$topdir/.pkgmeta"
fi

# Variables set via .pkgmeta.
package=
manual_changelog=
changelog=
changelog_markup="text"
enable_nolib_creation=
ignore=
contents=
nolib_exclude=
wowi_gen_changelog="true"
wowi_archive="true"
wowi_convert_changelog="true"
declare -A relations=()

parse_ignore() {
	pkgmeta="$1"
	[ -f "$pkgmeta" ] || return 1

	checkpath="$topdir" # paths are relative to the topdir
	copypath=""
	if [ "$2" != "" ]; then
		checkpath=$( dirname "$pkgmeta" )
		copypath="$2/"
	fi

	yaml_eof=
	while [ -z "$yaml_eof" ]; do
		IFS='' read -r yaml_line || yaml_eof="true"
		# Skip commented out lines.
		if [[ $yaml_line =~ ^[[:space:]]*\# ]]; then
			continue
		fi
		# Strip any trailing CR character.
		yaml_line=${yaml_line%$carriage_return}

		case $yaml_line in
		[!\ ]*:*)
			# Split $yaml_line into a $yaml_key, $yaml_value pair.
			yaml_keyvalue "$yaml_line"
			# Set the $pkgmeta_phase for stateful processing.
			pkgmeta_phase=$yaml_key
			;;
		[\ ]*"- "*)
			yaml_line=${yaml_line#"${yaml_line%%[! ]*}"} # trim leading whitespace
			# Get the YAML list item.
			yaml_listitem "$yaml_line"
			if [ "$pkgmeta_phase" = "ignore" ]; then
				pattern=$yaml_item
				if [ -d "$checkpath/$pattern" ]; then
					pattern="$copypath$pattern/*"
				elif [ ! -f "$checkpath/$pattern" ]; then
					# doesn't exist so match both a file and a path
					pattern="$copypath$pattern:$copypath$pattern/*"
				else
					pattern="$copypath$pattern"
				fi
				if [ -z "$ignore" ]; then
					ignore="$pattern"
				else
					ignore="$ignore:$pattern"
				fi
			fi
			;;
		esac
	done < "$pkgmeta"
}

if [ -f "$pkgmeta_file" ]; then
	yaml_eof=
	while [ -z "$yaml_eof" ]; do
		IFS='' read -r yaml_line || yaml_eof="true"
		# Skip commented out lines.
		if [[ $yaml_line =~ ^[[:space:]]*\# ]]; then
			continue
		fi
		# Strip any trailing CR character.
		yaml_line=${yaml_line%$carriage_return}

		case $yaml_line in
		[!\ ]*:*)
			# Split $yaml_line into a $yaml_key, $yaml_value pair.
			yaml_keyvalue "$yaml_line"
			# Set the $pkgmeta_phase for stateful processing.
			pkgmeta_phase=$yaml_key

			case $yaml_key in
			enable-nolib-creation)
				if [ "$yaml_value" = "yes" ]; then
					enable_nolib_creation="true"
				fi
				;;
			manual-changelog)
				changelog=$yaml_value
				manual_changelog="true"
				;;
			package-as)
				package=$yaml_value
				;;
			wowi-create-changelog)
				if [ "$yaml_value" = "no" ]; then
					wowi_gen_changelog=
				fi
				;;
			wowi-convert-changelog)
				if [ "$yaml_value" = "no" ]; then
					wowi_convert_changelog=
				fi
				;;
			wowi-archive-previous)
				if [ "$yaml_value" = "no" ]; then
					wowi_archive=
				fi
				;;
			esac
			;;
		" "*)
			yaml_line=${yaml_line#"${yaml_line%%[! ]*}"} # trim leading whitespace
			case $yaml_line in
			"- "*)
				# Get the YAML list item.
				yaml_listitem "$yaml_line"
				case $pkgmeta_phase in
				ignore)
					pattern=$yaml_item
					if [ -d "$topdir/$pattern" ]; then
						pattern="$pattern/*"
					elif [ ! -f "$topdir/$pattern" ]; then
						# doesn't exist so match both a file and a path
						pattern="$pattern:$pattern/*"
					fi
					if [ -z "$ignore" ]; then
						ignore="$pattern"
					else
						ignore="$ignore:$pattern"
					fi
					;;
				tools-used)
					relations["$yaml_item"]="tool"
					;;
				required-dependencies)
					relations["$yaml_item"]="requiredDependency"
					;;
				optional-dependencies)
					relations["$yaml_item"]="optionalDependency"
					;;
				embedded-libraries)
					relations["$yaml_item"]="embeddedLibrary"
					;;
				esac
				;;
			*:*)
				# Split $yaml_line into a $yaml_key, $yaml_value pair.
				yaml_keyvalue "$yaml_line"
				case $pkgmeta_phase in
				manual-changelog)
					case $yaml_key in
					filename)
						changelog=$yaml_value
						manual_changelog="true"
						;;
					markup-type)
						if [ "$yaml_value" = "markdown" ] || [ "$yaml_value" = "html" ]; then
							changelog_markup=$yaml_value
						else
							changelog_markup="text"
						fi
						;;
					esac
					;;
				esac
				;;
			esac
			;;
		esac
	done < "$pkgmeta_file"
fi

# Add untracked/ignored files to the ignore list
if [ "$repository_type" = "git" ]; then
	OLDIFS=$IFS
	IFS=$'\n'
	for _vcs_ignore in $(git -C "$topdir" ls-files --others --directory); do
		if [ -d "$topdir/$_vcs_ignore" ]; then
			_vcs_ignore="$_vcs_ignore*"
		fi
		if [ -z "$ignore" ]; then
			ignore="$_vcs_ignore"
		else
			ignore="$ignore:$_vcs_ignore"
		fi
	done
	IFS=$OLDIFS
elif [ "$repository_type" = "svn" ]; then
	# svn always being difficult.
	OLDIFS=$IFS
	IFS=$'\n'
	for _vcs_ignore in $( cd "$topdir" && svn status --no-ignore --ignore-externals | awk '/^[?IX]/' | cut -c9- | tr '\\' '/' ); do
		if [ -d "$topdir/$_vcs_ignore" ]; then
			_vcs_ignore="$_vcs_ignore/*"
		fi
		if [ -z "$ignore" ]; then
			ignore="$_vcs_ignore"
		else
			ignore="$ignore:$_vcs_ignore"
		fi
	done
	IFS=$OLDIFS
elif [ "$repository_type" = "hg" ]; then
	_vcs_ignore=$( hg --cwd "$topdir" status --ignored --unknown --no-status --print0 | tr '\0' ':' )
	if [ -n "$_vcs_ignore" ]; then
		_vcs_ignore=${_vcs_ignore:0:-1}
		if [ -z "$ignore" ]; then
			ignore="$_vcs_ignore"
		else
			ignore="$ignore:$_vcs_ignore"
		fi
	fi
fi

# TOC file processing.
tocfile=$(
	cd "$topdir" || exit
	filename=$( ls ./*.toc -1 2>/dev/null | head -n1 )
	if [[ -z "$filename" && -n "$package" ]]; then
		# Handle having the core addon in a sub dir, which people have starting doing
		# for some reason. Tons of caveats, just make the base dir your base addon people!
		filename=$( ls "$package"/*.toc -1 2>/dev/null | head -n1 )
	fi
	echo "$filename"
)
if [[ -z "$tocfile" || ! -f "$topdir/$tocfile" ]]; then
	echo "Could not find an addon TOC file. In another directory? Make sure it matches the 'package-as' in .pkgmeta" >&2
	exit 1
fi

# Set the package name from the TOC filename.
toc_name=$( basename "$tocfile" | sed 's/\.toc$//' )
if [[ -n "$package" && "$package" != "$toc_name" ]]; then
	echo "Addon package name does not match TOC file name." >&2
	exit 1
fi
if [ -z "$package" ]; then
	package="$toc_name"
fi

# Get the interface version for setting upload version.
toc_file=$( sed -e $'1s/^\xEF\xBB\xBF//' -e $'s/\r//g' "$topdir/$tocfile" ) # go away bom, crlf
if [ -n "$classic" ] && [ -z "$toc_version" ] && [ -z "$game_version" ]; then
	toc_version=$( echo "$toc_file" | awk '/## Interface:[[:space:]]*113/ { print $NF; exit }' )
fi
if [ -z "$toc_version" ]; then
	toc_version=$( echo "$toc_file" | awk '/^## Interface:/ { print $NF; exit }' )
	if [[ "$toc_version" == "113"* ]]; then
		classic="true"
	fi
fi
if [ -z "$game_version" ]; then
	game_version="${toc_version:0:1}.$( printf "%d" ${toc_version:1:2} ).$( printf "%d" ${toc_version:3:2} )"
fi

# Get the title of the project for using in the changelog.
project=$( echo "$toc_file" | awk '/^## Title:/ { print $0; exit }' | sed -e 's/## Title[[:space:]]*:[[:space:]]*\(.*\)[[:space:]]*/\1/' -e 's/|c[0-9A-Fa-f]\{8\}//g' -e 's/|r//g' )

# Get Wago ID
if [ -z "$wagoid" ]; then
	wagoid=$( awk '/^## X-Wago-ID:/ { print $NF; exit }' <<< "$toc_file" )
fi

unset toc_file

# unset project ids if they are set to 0
[ "$wagoid" = "0" ] && wagoid=

echo
echo "Packaging $package"
if [ -n "$project_version" ]; then
	echo "Current version: $project_version"
fi
if [ -n "$previous_version" ]; then
	echo "Previous version: $previous_version"
fi
(
	[ -n "$classic" ] && retail="non-retail" || retail="retail"
	[ -z "$alpha" ] && alpha="non-alpha" || alpha="alpha"
	echo "Build type: ${retail} ${alpha} non-debug${nolib:+ nolib}"
	echo "Game version: ${game_version}"
	echo
)
if [ -n "$wagoid" ]; then
	echo "Wago ID: $wagoid${wago_token:+ [token set]}"
fi
if [ -n "$project_github_slug" ]; then
	echo "GitHub: $project_github_slug${github_token:+ [token set]}"
fi
if [ -n "$project_site" ] || [ -n "$project_github_slug" ]; then
	echo
fi
echo
echo "Checkout directory: $topdir"
echo "Release directory: $releasedir"
echo

# Set $pkgdir to the path of the package directory inside $releasedir.
pkgdir="$releasedir/$package"
if [ -d "$pkgdir" ] && [ -z "$overwrite" ]; then
	#echo "Removing previous package directory: $pkgdir"
	rm -fr "$pkgdir"
fi
if [ ! -d "$pkgdir" ]; then
	mkdir -p "$pkgdir"
fi

# Set the contents of the addon zipfile.
contents="$package"

###
### Create filters for pass-through processing of files to replace repository keywords.
###

escape_substr() {
	local s="$*"
	s=${s//\\/\\\\}
	s=${s//\//\\/}
	s=${s//&/\\&}
	echo "$s"
}

# Filter for simple repository keyword replacement.
vcs_filter() {
	sed \
		-e "s/@project-revision@/$si_project_revision/g" \
		-e "s/@project-hash@/$si_project_hash/g" \
		-e "s/@project-abbreviated-hash@/$si_project_abbreviated_hash/g" \
		-e "s/@project-author@/$( escape_substr "$si_project_author" )/g" \
		-e "s/@project-date-iso@/$si_project_date_iso/g" \
		-e "s/@project-date-integer@/$si_project_date_integer/g" \
		-e "s/@project-timestamp@/$si_project_timestamp/g" \
		-e "s/@project-version@/$si_project_version/g" \
		-e "s/@file-revision@/$si_file_revision/g" \
		-e "s/@file-hash@/$si_file_hash/g" \
		-e "s/@file-abbreviated-hash@/$si_file_abbreviated_hash/g" \
		-e "s/@file-author@/$( escape_substr "$si_file_author" )/g" \
		-e "s/@file-date-iso@/$si_file_date_iso/g" \
		-e "s/@file-date-integer@/$si_file_date_integer/g" \
		-e "s/@file-timestamp@/$si_file_timestamp/g"
}

lua_filter() {
	local level
	case $1 in
		alpha)  level="="    ;;
		debug)  level="=="   ;;
		retail) level="====" ;;
		*)      level="==="
	esac
	sed \
		-e "s/--@$1@/--[${level}[@$1@/g" \
		-e "s/--@end-$1@/--@end-$1@]${level}]/g" \
		-e "s/--\[===\[@non-$1@/--@non-$1@/g" \
		-e "s/--@end-non-$1@\]===\]/--@end-non-$1@/g"
}

toc_filter() {
	_trf_token=$1; shift
	_trf_comment=
	_trf_eof=
	while [ -z "$_trf_eof" ]; do
		IFS='' read -r _trf_line || _trf_eof="true"
		# Strip any trailing CR character.
		_trf_line=${_trf_line%$carriage_return}
		_trf_passthrough=
		case $_trf_line in
		"#@${_trf_token}@"*)
			_trf_comment="# "
			_trf_passthrough="true"
			;;
		"#@end-${_trf_token}@"*)
			_trf_comment=
			_trf_passthrough="true"
			;;
		esac
		if [ -z "$_trf_passthrough" ]; then
			_trf_line="$_trf_comment$_trf_line"
		fi
		if [ -n "$_trf_eof" ]; then
			echo -n "$_trf_line"
		else
			echo "$_trf_line"
		fi
	done
}

toc_filter2() {
	_trf_token=$1
	_trf_action=1
	if [ "$2" = "true" ]; then
		_trf_action=0
	fi
	shift 2
	_trf_keep=1
	_trf_uncomment=
	_trf_eof=
	while [ -z "$_trf_eof" ]; do
		IFS='' read -r _trf_line || _trf_eof="true"
		# Strip any trailing CR character.
		_trf_line=${_trf_line%$carriage_return}
		case $_trf_line in
		*"#@$_trf_token@"*)
			# remove the tokens, keep the content
			_trf_keep=$_trf_action
			;;
		*"#@non-$_trf_token@"*)
			# remove the tokens, remove the content
			_trf_keep=$(( 1-_trf_action ))
			_trf_uncomment="true"
			;;
		*"#@end-$_trf_token@"*|*"#@end-non-$_trf_token@"*)
			# remove the tokens
			_trf_keep=1
			_trf_uncomment=
			;;
		*)
			if (( _trf_keep )); then
				if [ -n "$_trf_uncomment" ]; then
					_trf_line="${_trf_line#\# }"
				fi
				if [ -n "$_trf_eof" ]; then
					echo -n "$_trf_line"
				else
					echo "$_trf_line"
				fi
			fi
			;;
		esac
	done
}

xml_filter() {
	sed \
		-e "s/<!--@$1@-->/<!--@$1/g" \
		-e "s/<!--@end-$1@-->/@end-$1@-->/g" \
		-e "s/<!--@non-$1@/<!--@non-$1@-->/g" \
		-e "s/@end-non-$1@-->/<!--@end-non-$1@-->/g"
}

do_not_package_filter() {
	_dnpf_token=$1; shift
	_dnpf_string="do-not-package"
	_dnpf_start_token=
	_dnpf_end_token=
	case $_dnpf_token in
	lua)
		_dnpf_start_token="--@$_dnpf_string@"
		_dnpf_end_token="--@end-$_dnpf_string@"
		;;
	toc)
		_dnpf_start_token="#@$_dnpf_string@"
		_dnpf_end_token="#@end-$_dnpf_string@"
		;;
	xml)
		_dnpf_start_token="<!--@$_dnpf_string@-->"
		_dnpf_end_token="<!--@end-$_dnpf_string@-->"
		;;
	esac
	if [ -z "$_dnpf_start_token" ] || [ -z "$_dnpf_end_token" ]; then
		cat
	else
		# Replace all content between the start and end tokens, inclusive, with a newline to match CF packager.
		_dnpf_eof=
		_dnpf_skip=
		while [ -z "$_dnpf_eof" ]; do
			IFS='' read -r _dnpf_line || _dnpf_eof="true"
			# Strip any trailing CR character.
			_dnpf_line=${_dnpf_line%$carriage_return}
			case $_dnpf_line in
			*$_dnpf_start_token*)
				_dnpf_skip="true"
				echo -n "${_dnpf_line%%${_dnpf_start_token}*}"
				;;
			*$_dnpf_end_token*)
				_dnpf_skip=
				if [ -z "$_dnpf_eof" ]; then
					echo ""
				fi
				;;
			*)
				if [ -z "$_dnpf_skip" ]; then
					if [ -n "$_dnpf_eof" ]; then
						echo -n "$_dnpf_line"
					else
						echo "$_dnpf_line"
					fi
				fi
				;;
			esac
		done
	fi
}

line_ending_filter() {
	_lef_eof=
	while [ -z "$_lef_eof" ]; do
		IFS='' read -r _lef_line || _lef_eof="true"
		# Strip any trailing CR character.
		_lef_line=${_lef_line%$carriage_return}
		if [ -n "$_lef_eof" ]; then
			# Preserve EOF not preceded by newlines.
			echo -n "$_lef_line"
		else
			case $line_ending in
			dos)
				# Terminate lines with CR LF.
				printf "%s\r\n" "$_lef_line"
				;;
			unix)
				# Terminate lines with LF.
				printf "%s\n" "$_lef_line"
				;;
			esac
		fi
	done
}

###
### Copy files from the working directory into the package directory.
###

# Copy of the contents of the source directory into the destination directory.
# Dotfiles and any files matching the ignore pattern are skipped.  Copied files
# are subject to repository keyword replacement.
#
copy_directory_tree() {
	_cdt_alpha=
	_cdt_debug=
	_cdt_ignored_patterns=
	_cdt_nolib=
	_cdt_do_not_package=
	_cdt_unchanged_patterns=
	_cdt_classic=
	OPTIND=1
	while getopts :adi:lnpu:c _cdt_opt "$@"; do
		# shellcheck disable=2220
		case $_cdt_opt in
			a)	_cdt_alpha="true" ;;
			d)	_cdt_debug="true" ;;
			i)	_cdt_ignored_patterns=$OPTARG ;;
			n)	_cdt_nolib="true" ;;
			p)	_cdt_do_not_package="true" ;;
			u)	_cdt_unchanged_patterns=$OPTARG ;;
			c)	_cdt_classic="true" ;;
		esac
	done
	shift $((OPTIND - 1))
	_cdt_srcdir=$1
	_cdt_destdir=$2

	if [ -z "$_external_dir" ]; then
		start_group "Copying files into ${_cdt_destdir#$topdir/}:" "copy"
	else # don't nest groups
		echo "Copying files into ${_cdt_destdir#$topdir/}:"
	fi
	if [ ! -d "$_cdt_destdir" ]; then
		mkdir -p "$_cdt_destdir"
	fi
	# Create a "find" command to list all of the files in the current directory, minus any ones we need to prune.
	_cdt_find_cmd="find ."
	# Prune everything that begins with a dot except for the current directory ".".
	_cdt_find_cmd+=" \( -name \".*\" -a \! -name \".\" \) -prune"
	# Prune the destination directory if it is a subdirectory of the source directory.
	_cdt_dest_subdir=${_cdt_destdir#${_cdt_srcdir}/}
	case $_cdt_dest_subdir in
		/*)	;;
		*)	_cdt_find_cmd+=" -o -path \"./$_cdt_dest_subdir\" -prune" ;;
	esac
	# Print the filename, but suppress the current directory ".".
	_cdt_find_cmd+=" -o \! -name \".\" -print"
	( cd "$_cdt_srcdir" && eval "$_cdt_find_cmd" ) | while read -r file; do
		file=${file#./}
		if [ -f "$_cdt_srcdir/$file" ]; then
			# Check if the file should be ignored.
			skip_copy=
			# Prefix external files with the relative pkgdir path
			_cdt_check_file=$file
			if [ -n "${_cdt_destdir#$pkgdir}" ]; then
				_cdt_check_file="${_cdt_destdir#$pkgdir/}/$file"
			fi
			# Skip files matching the colon-separated "ignored" shell wildcard patterns.
			if [ -z "$skip_copy" ] && match_pattern "$_cdt_check_file" "$_cdt_ignored_patterns"; then
				skip_copy="true"
			fi
			# Never skip files that match the colon-separated "unchanged" shell wildcard patterns.
			unchanged=
			if [ -n "$skip_copy" ] && match_pattern "$file" "$_cdt_unchanged_patterns"; then
				skip_copy=
				unchanged="true"
			fi
			# Copy unskipped files into $_cdt_destdir.
			if [ -n "$skip_copy" ]; then
				echo "  Ignoring: $file"
			else
				dir=${file%/*}
				if [ "$dir" != "$file" ]; then
					mkdir -p "$_cdt_destdir/$dir"
				fi
				# Check if the file matches a pattern for keyword replacement.
				if [ -n "$unchanged" ] || ! match_pattern "$file" "*.lua:*.md:*.toc:*.txt:*.xml"; then
					echo "  Copying: $file (unchanged)"
					cp "$_cdt_srcdir/$file" "$_cdt_destdir/$dir"
				else
					# Set the filters for replacement based on file extension.
					_cdt_filters="vcs_filter"
					case $file in
						*.lua)
							[ -n "$_cdt_alpha" ] && _cdt_filters+="|lua_filter alpha"
							[ -n "$_cdt_debug" ] && _cdt_filters+="|lua_filter debug"
							[ -n "$_cdt_do_not_package" ] && _cdt_filters+="|do_not_package_filter lua"
							[ -n "$_cdt_classic" ] && _cdt_filters+="|lua_filter retail"
							;;
						*.xml)
							[ -n "$_cdt_alpha" ] && _cdt_filters+="|xml_filter alpha"
							[ -n "$_cdt_debug" ] && _cdt_filters+="|xml_filter debug"
							[ -n "$_cdt_nolib" ] && _cdt_filters+="|xml_filter no-lib-strip"
							[ -n "$_cdt_do_not_package" ] && _cdt_filters+="|do_not_package_filter xml"
							[ -n "$_cdt_classic" ] && _cdt_filters+="|xml_filter retail"
							;;
						*.toc)
							_cdt_filters+="|toc_filter2 alpha ${_cdt_alpha:-0}"
							_cdt_filters+="|toc_filter2 debug ${_cdt_debug:-0}"
							_cdt_filters+="|toc_filter2 no-lib-strip ${_cdt_nolib:-0}"
							_cdt_filters+="|toc_filter2 do-not-package ${_cdt_do_not_package:-0}"
							_cdt_filters+="|toc_filter2 retail ${_cdt_classic:-0}"
							;;
					esac

					# Set the filter for normalizing line endings.
					_cdt_filters+="|line_ending_filter"

					# Set version control values for the file.
					set_info_file "$_cdt_srcdir/$file"

					echo "  Copying: $file"
					eval < "$_cdt_srcdir/$file" "$_cdt_filters" > "$_cdt_destdir/$file"
				fi
			fi
		fi
	done
	if [ -z "$_external_dir" ]; then
		end_group "copy"
	fi
}

if [ -z "$skip_copying" ]; then
	cdt_args="-dp"
	[ -z "$alpha" ] && cdt_args+="a"
	[ -n "$nolib" ] && cdt_args+="n"
	[ -n "$classic" ] && cdt_args+="c"
	[ -n "$ignore" ] && cdt_args+=" -i \"$ignore\""
	[ -n "$changelog" ] && cdt_args+=" -u \"$changelog\""
	eval copy_directory_tree "$cdt_args" "\"$topdir\"" "\"$pkgdir\""
fi

# Reset ignore and parse pkgmeta ignores again to handle ignoring external paths
ignore=
parse_ignore "$pkgmeta_file"

# Restore the signal handlers
trap - INT

###
### Create the changelog of commits since the previous release tag.
###

if [ -z "$project" ]; then
	project="$package"
fi

# Create a changelog in the package directory if the source directory does
# not contain a manual changelog.
if [ -n "$manual_changelog" ] && [ -f "$topdir/$changelog" ]; then
	start_group "Using manual changelog at $changelog" "changelog"
	head -n7 "$topdir/$changelog"
	[ "$( wc -l < "$topdir/$changelog" )" -gt 7 ] && echo "..."
	end_group "changelog"
else
	if [ -n "$manual_changelog" ]; then
		echo "Warning! Could not find a manual changelog at $topdir/$changelog"
		manual_changelog=
	fi
	changelog="CHANGELOG.md"
	changelog_markup="markdown"

	start_group "Generating changelog of commits into $changelog" "changelog"

	_changelog_range=

	if [ -z "$previous_version" ] && [ -z "$tag" ]; then
		# no range, show all commits up to ours
		_changelog_range="$project_hash"
	elif [ -z "$previous_version" ] && [ -n "$tag" ]; then
		# first tag, show all commits upto it
		_changelog_range="$tag"
	elif [ -n "$previous_version" ] && [ -z "$tag" ]; then
		# compare between last tag and our commit
		_changelog_range="$previous_version..$project_hash"
	elif [ -n "$previous_version" ] && [ -n "$tag" ]; then
		# compare between last tag and our tag
		_changelog_range="$previous_version..$tag"
	fi

	git -C "$topdir" log "$_changelog_range" --pretty=format:"###%B" \
		| sed -e 's/^/    /g' -e 's/^ *$//g' -e 's/^    ###/- /g' -e 's/$/  /' \
				-e 's/\([a-zA-Z0-9]\)_\([a-zA-Z0-9]\)/\1\\_\2/g' \
				-e 's/\[ci skip\]//g' -e 's/\[skip ci\]//g' \
				-e '/git-svn-id:/d' -e '/^[[:space:]]*This reverts commit [0-9a-f]\{40\}\.[[:space:]]*$/d' \
				-e '/^[[:space:]]*$/d' \
		| line_ending_filter >> "$pkgdir/$changelog"

	echo "$(<"$pkgdir/$changelog")"
	end_group "changelog"
fi

###
### Process .pkgmeta to perform move-folders actions.
###

if [ -f "$pkgmeta_file" ]; then
	yaml_eof=
	while [ -z "$yaml_eof" ]; do
		IFS='' read -r yaml_line || yaml_eof="true"
		# Skip commented out lines.
		if [[ $yaml_line =~ ^[[:space:]]*\# ]]; then
			continue
		fi
		# Strip any trailing CR character.
		yaml_line=${yaml_line%$carriage_return}

		case $yaml_line in
		[!\ ]*:*)
			# Split $yaml_line into a $yaml_key, $yaml_value pair.
			yaml_keyvalue "$yaml_line"
			# Set the $pkgmeta_phase for stateful processing.
			pkgmeta_phase=$yaml_key
			;;
		" "*)
			yaml_line=${yaml_line#"${yaml_line%%[! ]*}"} # trim leading whitespace
			case $yaml_line in
			"- "*)
				;;
			*:*)
				# Split $yaml_line into a $yaml_key, $yaml_value pair.
				yaml_keyvalue "$yaml_line"
				case $pkgmeta_phase in
				move-folders)
					srcdir="$releasedir/$yaml_key"
					destdir="$releasedir/$yaml_value"
					if [[ -d "$destdir" && -z "$overwrite" && "$srcdir" != "$destdir/"* ]]; then
						rm -fr "$destdir"
					fi
					if [ -d "$srcdir" ]; then
						if [ ! -d "$destdir" ]; then
							mkdir -p "$destdir"
						fi
						echo "Moving $yaml_key to $yaml_value"
						mv -f "$srcdir"/* "$destdir" && rm -fr "$srcdir"
						contents="$contents $yaml_value"
						# Check to see if the base source directory is empty
						_mf_basedir=${srcdir%$(basename "$yaml_key")}
						if [ ! "$( ls -A "$_mf_basedir" )" ]; then
							echo "Removing empty directory ${_mf_basedir#$releasedir/}"
							rm -fr "$_mf_basedir"
						fi
					fi
					# update external dir
					nolib_exclude=${nolib_exclude//$srcdir/$destdir}
					;;
				esac
				;;
			esac
			;;
		esac
	done < "$pkgmeta_file"
	if [ -n "$srcdir" ]; then
		echo
	fi
fi

###
### Create the final zipfile for the addon.
###

if [ -z "$skip_zipfile" ]; then
	archive_package_name="${package//[^A-Za-z0-9._-]/_}"

	classic_tag=
	if [[ -n "$classic" && "${project_version,,}" != *"classic"* ]]; then
		# if it's a classic build, and classic isn't in the name, append it for clarity
		classic_tag="-classic"
	fi

	archive_version="$project_version"
	archive_name="$archive_package_name-$project_version$classic_tag.zip"
	archive="$releasedir/$archive_name"

	nolib_archive_version="$project_version-nolib"
	nolib_archive_name="$archive_package_name-$nolib_archive_version$classic_tag.zip"
	nolib_archive="$releasedir/$nolib_archive_name"

	if [ -n "$nolib" ]; then
		archive_version="$nolib_archive_version"
		archive_name="$nolib_archive_name"
		archive="$nolib_archive"
		nolib_archive=
	fi

	start_group "Creating archive: $archive_name" "archive"
	if [ -f "$archive" ]; then
		rm -f "$archive"
	fi
	( cd "$releasedir" && zip -X -r "$archive" $contents )

	if [ ! -f "$archive" ]; then
		exit 1
	fi
	end_group "archive"

	# Create nolib version of the zipfile
	if [ -n "$enable_nolib_creation" ] && [ -z "$nolib" ] && [ -n "$nolib_exclude" ]; then
		# run the nolib_filter
		find "$pkgdir" -type f \( -name "*.xml" -o -name "*.toc" \) -print | while read -r file; do
			case $file in
			*.toc)	_filter="toc_filter2 no-lib-strip" ;;
			*.xml)	_filter="xml_filter no-lib-strip" ;;
			esac
			$_filter < "$file" > "$file.tmp" && mv "$file.tmp" "$file"
		done

		# make the exclude paths relative to the release directory
		nolib_exclude=${nolib_exclude//$releasedir\//}

		start_group "Creating no-lib archive: $nolib_archive_name" "archive.nolib"
		if [ -f "$nolib_archive" ]; then
			rm -f "$nolib_archive"
		fi
		# set noglob so each nolib_exclude path gets quoted instead of expanded
		( set -f; cd "$releasedir" && zip -X -r -q "$nolib_archive" $contents -x $nolib_exclude )

		if [ ! -f "$nolib_archive" ]; then
			exit_code=1
		fi
		end_group "archive.nolib"
	fi

	###
	### Deploy the zipfile.
	###

	upload_wago=$( [[ -z "$skip_upload" && -n "$wagoid" && -n "$wago_token" ]] && echo true )
	upload_github=$( [[ -z "$skip_upload" && -n "$tag" && -n "$project_github_slug" && -n "$github_token" ]] && echo true )

	if [[ -n "$upload_github" || -n "$upload_wago" ]] && ! hash jq &>/dev/null; then
		echo "Skipping upload because \"jq\" was not found."
		echo
		upload_github=
		exit_code=1
	fi

	# Upload to Wago
	if [ -n "$upload_wago" ] ; then
		_wago_support_property=""
		_wago_support_property+="\"supported_retail_patch\": \"${game_version}\", "

		if [ -n "$alpha" ]; then
			_wago_stability="beta"
		else
			_wago_stability="stable"
		fi

		_wago_payload=$( cat <<-EOF
		{
		  "label": "$archive_version",
		  $_wago_support_property
		  "stability": "$_wago_stability",
		  "changelog": $( jq --slurp --raw-input '.' < "$pkgdir/$changelog" )
		}
		EOF
		)

		echo "Uploading $archive_name ($game_version) to Wago"
		resultfile="$releasedir/wago_result.json"
		result=$( echo "$_wago_payload" | curl -sS --retry 3 --retry-delay 10 \
				-w "%{http_code}" -o "$resultfile" \
				-H "authorization: Bearer $wago_token" \
				-H "accept: application/json" \
				-F "metadata=<-" \
				-F "file=@$archive" \
				"https://addons.wago.io/api/projects/$wagoid/version"
		) && {
			case $result in
				200|201) echo "Success!" ;;
				302)
					echo "Error! ($result)"
					# don't need to ouput the redirect page
					exit_code=1
					;;
				404)
					echo "Error! No Wago project for id \"$wagoid\" found."
					exit_code=1
					;;
				*)
					echo "Error! ($result)"
					if [ -s "$resultfile" ]; then
						echo "$(<"$resultfile")"
					fi
					exit_code=1
					;;
			esac
		} || {
			exit_code=1
		}
		echo

		rm -f "$resultfile" 2>/dev/null
	fi

	# Create a GitHub Release for tags and upload the zipfile as an asset.
	if [ -n "$upload_github" ]; then
		upload_github_asset() {
			_ghf_release_id=$1
			_ghf_file_name=$2
			_ghf_file_path=$3
			_ghf_resultfile="$releasedir/gh_asset_result.json"

			# check if an asset exists and delete it (editing a release)
			asset_id=$( curl -sS -H "Authorization: token $github_token" "https://api.github.com/repos/$project_github_slug/releases/$_ghf_release_id/assets" | jq '.[] | select(.name? == "'"$_ghf_file_name"'") | .id' )
			if [ -n "$asset_id" ]; then
				curl -s -H "Authorization: token $github_token" -X DELETE "https://api.github.com/repos/$project_github_slug/releases/assets/$asset_id" &>/dev/null
			fi

			echo -n "Uploading $_ghf_file_name... "
			result=$( curl -sS --retry 3 --retry-delay 10 \
					-w "%{http_code}" -o "$_ghf_resultfile" \
					-H "Authorization: token $github_token" \
					-H "Content-Type: application/zip" \
					--data-binary "@$_ghf_file_path" \
					"https://uploads.github.com/repos/$project_github_slug/releases/$_ghf_release_id/assets?name=$_ghf_file_name" ) &&
			{
				if [ "$result" = "201" ]; then
					echo "Success!"
				else
					echo "Error ($result)"
					if [ -s "$_ghf_resultfile" ]; then
						echo "$(<"$_ghf_resultfile")"
					fi
					exit_code=1
				fi
			} || {
				exit_code=1
			}

			rm -f "$_ghf_resultfile" 2>/dev/null
			return 0
		}

		_gh_payload=$( cat <<-EOF
		{
		  "tag_name": "$tag",
		  "name": "$tag",
		  "body": $( jq --slurp --raw-input '.' < "$pkgdir/$changelog" ),
		  "draft": false,
		  "prerelease": $( [[ -n "$alpha" ]] && echo true || echo false )
		}
		EOF
		)
		resultfile="$releasedir/gh_result.json"

		release_id=$( curl -sS -H "Authorization: token $github_token" "https://api.github.com/repos/$project_github_slug/releases/tags/$tag" | jq '.id // empty' )
		if [ -n "$release_id" ]; then
			echo "Updating GitHub release: https://github.com/$project_github_slug/releases/tag/$tag"
			_gh_release_url="-X PATCH https://api.github.com/repos/$project_github_slug/releases/$release_id"
		else
			echo "Creating GitHub release: https://github.com/$project_github_slug/releases/tag/$tag"
			_gh_release_url="https://api.github.com/repos/$project_github_slug/releases"
		fi
		result=$( echo "$_gh_payload" | curl -sS --retry 3 --retry-delay 10 \
				-w "%{http_code}" -o "$resultfile" \
				-H "Authorization: token $github_token" \
				-d @- \
				$_gh_release_url ) &&
		{
			if [ "$result" = "200" ] || [ "$result" = "201" ]; then # edited || created
				if [ -z "$release_id" ]; then
					release_id=$( jq '.id' < "$resultfile" )
				fi
				upload_github_asset "$release_id" "$archive_name" "$archive"
				if [ -f "$nolib_archive" ]; then
					upload_github_asset "$release_id" "$nolib_archive_name" "$nolib_archive"
				fi
			else
				echo "Error! ($result)"
				if [ -s "$resultfile" ]; then
					echo "$(<"$resultfile")"
				fi
				exit_code=1
			fi
		} || {
			exit_code=1
		}

		rm -f "$resultfile" 2>/dev/null
		echo
	fi
fi

# All done.

echo
echo "Packaging complete."
echo

exit $exit_code
