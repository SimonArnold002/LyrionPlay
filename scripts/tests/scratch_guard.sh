# (c) 2026 CrystalGipsy, for LyrionPlay. MIT, as the app it tests.
#
# The scratch dir guard of the planted-bug runners (mutants_default_name.sh, mutants_now_playing.sh),
# sourced by both: ONE copy, run with hostile paths by scripts/tests/test_scratch_guard.sh in the
# regression suite. A runner deletes and remakes folders in the scratch dir it is given; a guard
# copied into each runner, and checked on the path as typed, deleted the repo's own app/ (/code-review
# 2026-11-22 (3) findings 3-4, 2026-11-23 finding 7, 2026-11-23 (2) finding 1).
#
#   scratch_dir <repo> [<scratch dir>]   sets WORK: with no scratch dir a new temporary folder,
#                                        removed at exit; else that dir, made if missing, or exit 2
#                                        having made nothing
#   remake <folder>...                   deletes and remakes each folder in WORK, marked as made here
#
# Two guards, each enough on its own:
#   1. the scratch dir must not be the repo or in it. Its folders that exist are resolved by the
#      kernel (cd + pwd -P: links, "..", the case it was typed in) and compared as folders (-ef);
#      the folders still to be made must be plain names, since a ".." after a folder that does not
#      exist yet is resolved only once mkdir has made that folder. They are made one by one, then the
#      whole dir is resolved and checked again; a refusal then removes only the folders just made.
#   2. remake deletes only a folder that holds the mark it leaves ($MARK): a folder of the same name
#      that a runner did not make (the repo's app/, a link, the user's own) stops the runner instead.
MARK=.made-by-mutants

_sg_refuse() { echo "refused: $*" >&2; exit 2; }

# _sg_in_repo <resolved folder> <repo>: true if the folder or any folder above it is the repo
_sg_in_repo() {
	_sg_d=$1
	while :; do
		[ "$_sg_d" -ef "$2" ] && return 0
		[ "$_sg_d" = / ] && return 1
		_sg_d=$(dirname "$_sg_d")
	done
}

# removes the folders scratch_dir made, deepest first, each only if still an empty folder
_sg_undo() {
	printf '%s' "$_sg_made" | while IFS= read -r _sg_d; do
		[ -n "$_sg_d" ] && [ -d "$_sg_d" ] && [ ! -L "$_sg_d" ] && rmdir "$_sg_d" 2>/dev/null
	done
}

scratch_dir() {
	_sg_repo=$1 _sg_made=''
	if [ $# -lt 2 ]; then
		WORK=$(mktemp -d) || exit 1
		trap 'rm -rf "$WORK"' EXIT
		return
	fi
	_sg_dir=$2
	[ -n "$_sg_dir" ] || _sg_refuse "an empty scratch dir; give one outside the repo ($_sg_repo), or none"
	case $_sg_dir in *'
'*) _sg_refuse "a scratch dir with a line break in it" ;; esac
	case $_sg_dir in /*) _sg_path=$_sg_dir ;; *) _sg_path=./$_sg_dir ;; esac
	# up to the nearest folder that exists; what is below it must be plain names, none there yet
	_sg_new=''
	while [ ! -d "$_sg_path" ]; do
		if [ -e "$_sg_path" ] || [ -L "$_sg_path" ]; then
			_sg_refuse "$_sg_dir: $_sg_path is there but is not a folder"
		fi
		_sg_name=$(basename "$_sg_path")
		case $_sg_name in
			. | ..) _sg_refuse "$_sg_dir: \"$_sg_name\" after a folder that does not exist yet; give the path without it" ;;
		esac
		_sg_new=$_sg_name${_sg_new:+/$_sg_new}
		_sg_path=$(dirname "$_sg_path")
	done
	WORK=$(cd "$_sg_path" && pwd -P) || _sg_refuse "$_sg_dir: $_sg_path cannot be opened"
	_sg_in_repo "$WORK" "$_sg_repo" && _sg_refuse "$_sg_dir is in the repo ($_sg_repo); give a scratch dir outside it, or none"
	# made one by one (mkdir, not -p): each is new, and the list is what a refusal may remove
	while [ -n "$_sg_new" ]; do
		_sg_name=${_sg_new%%/*}
		case $_sg_new in */*) _sg_new=${_sg_new#*/} ;; *) _sg_new='' ;; esac
		WORK=${WORK%/}/$_sg_name
		mkdir "$WORK" || { _sg_undo; _sg_refuse "$_sg_dir: $WORK could not be made"; }
		_sg_made="$WORK
$_sg_made"
	done
	# checked again on what was made: guard 1 must hold for the folder the runner will use
	_sg_real=$(cd "$WORK" && pwd -P) || { _sg_undo; _sg_refuse "$_sg_dir: $WORK cannot be opened"; }
	if _sg_in_repo "$_sg_real" "$_sg_repo"; then
		_sg_undo; _sg_refuse "$_sg_dir is in the repo ($_sg_repo); give a scratch dir outside it, or none"
	fi
	WORK=$_sg_real
}

remake() {
	for _sg_f in "$@"; do
		if [ -L "$WORK/$_sg_f" ] || { [ -e "$WORK/$_sg_f" ] && { [ ! -f "$WORK/$_sg_f/$MARK" ] || [ -L "$WORK/$_sg_f/$MARK" ]; }; }; then
			_sg_refuse "$WORK/$_sg_f was not made by a planted-bug runner (no $MARK in it): not deleted; give another scratch dir"
		fi
	done
	for _sg_f in "$@"; do
		rm -rf "$WORK/$_sg_f"
		mkdir "$WORK/$_sg_f" && : > "$WORK/$_sg_f/$MARK" || exit 1
	done
}
