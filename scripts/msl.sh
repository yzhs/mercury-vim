#!/bin/sh

# msl - Mercury SICStus Prolog Linker.
#
# Loads SICStus object files (*.ql) together with the Mercury library
# into the SICStus interpreter, and then saves the state to produce an
# executable binary.
#
# Usage: msl [<options>] files...
# Options:
#	-v, --verbose
#	-d, --debug
#	-o, --output
# Environment variables: MERCURY_SP_LIB_DIR, MERCURY_SP_LIB_OBJS

SP=${MERCURY_SICSTUS_PROLOG:-msp}
SPLIBDIR=${MERCURY_SP_LIB_DIR:-@LIBDIR@/sicstus/@FULLARCH@}
LIBRARY_OBJS=${MERCURY_SP_LIB_OBJS:-`cd $SPLIBDIR; echo *.ql`}

verbose=false
debug=false
target=a.out

while true; do
	case "$1" in
		-v|--verbose)
			verbose=true
			shift
			;;
		-d|--debug)
			debug=true
			shift
			;;
		-o|--output)
			target=$2
			shift 2
			;;
		-*)	
			echo "$0: invalid option \`$1'" 1>&2
			exit 1
			;;
		*)	break 2
			;;
	esac
done
if $debug; then
	LIBRARY_OBJS="$LIBRARY_OBJS error.ql"
fi

objlist=
for obj in sp_builtin.ql $LIBRARY_OBJS; do
	if echo "" "$objlist" "$@" "" | grep " $obj " > /dev/null; then
		true
	else
		objlist="$objlist $SPLIBDIR/$obj"
	fi
done

if $verbose; then
	echo Linking $objlist
fi
if $debug; then
	$SP $objlist "$@" 2>&1 << EOF
	on_exception(Error, (
		write(1), nl,
	  prolog_flag(compiling, _, fastcode),
		write(2), nl,
	  unix(argv(Files)), load(Files),
		write(3), nl,
	  save('$target', _),
		write(4), nl,
	  fail
	), print_message(error, Error)), halt) ; true.
EOF
else
	sp $objlist "$@" 2>&1 << EOF
	on_exception(Error, (
	  prolog_flag(compiling, _, fastcode),
	  unix(argv(Files)), load(Files),
	  garbage_collect,
	  save('$target', 1),
	  unix(argv(Args)), run([mc|Args])
	), print_message(error, Error)), halt ; halt.
	e
	e
	e
	e
EOF
fi # grep -v 'DOMAIN ERROR.*when_condition' 
# We pipe the output through grep -v to suppress some spurious warnings
# caused by the NU-Prolog when declarations not matching Sicstus syntax.
