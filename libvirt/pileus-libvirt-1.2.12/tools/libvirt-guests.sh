#!/bin/sh

# Copyright (C) 2011-2014 Red Hat, Inc.
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2.1 of the License, or (at your option) any later version.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this library.  If not, see
# <http://www.gnu.org/licenses/>.

sysconfdir="/etc"
localstatedir="/var"
libvirtd="/usr/sbin"/libvirtd

# Source function library.
test ! -r "$sysconfdir"/rc.d/init.d/functions ||
    . "$sysconfdir"/rc.d/init.d/functions

# Source gettext library.
# Make sure this file is recognized as having translations: _("dummy")
. "/usr/bin"/gettext.sh

export TEXTDOMAIN="libvirt" TEXTDOMAINDIR="/usr/share/locale"

URIS=default
ON_BOOT=start
ON_SHUTDOWN=suspend
SHUTDOWN_TIMEOUT=300
PARALLEL_SHUTDOWN=0
START_DELAY=0
BYPASS_CACHE=0
CONNECT_RETRIES=10
RETRIES_SLEEP=1

test -f "$sysconfdir"/sysconfig/libvirt-guests &&
    . "$sysconfdir"/sysconfig/libvirt-guests

LISTFILE="$localstatedir"/lib/libvirt/libvirt-guests
VAR_SUBSYS_LIBVIRT_GUESTS="$localstatedir"/lock/subsys/libvirt-guests

RETVAL=0

# retval COMMAND ARGUMENTS...
# run command with arguments and convert non-zero return value to 1 and set
# the global return variable
retval() {
    "$@"
    if [ $? -ne 0 ]; then
        RETVAL=1
        return 1
    else
        return 0
    fi
}

# run_virsh URI ARGUMENTS...
# start virsh and let it execute ARGUMENTS on URI
# If URI is "default" virsh is called without the "-c" argument
# (using libvirt's default connection)
run_virsh() {
    uri=$1
    shift

    if [ "x$uri" = xdefault ]; then
        virsh "$@" </dev/null
    else
        virsh -c "$uri" "$@" </dev/null
    fi
}

# run_virsh_c URI ARGUMENTS
# Same as "run_virsh" but the "C" locale is used instead of
# the system's locale.
run_virsh_c() {
    ( export LC_ALL=C; run_virsh "$@" )
}

# test_connect URI
# check if URI is reachable
test_connect()
{
    uri=$1

    i=${CONNECT_RETRIES}
    while [ $i -gt 0 ]; do
        run_virsh "$uri" connect 2>/dev/null
        if [ $? -eq 0 ]; then
            return 0;
        fi
        sleep ${RETRIES_SLEEP}
        eval_gettext "Unable to connect to libvirt currently. Retrying .. \$i"
        i=$(($i-1))
    done
    eval_gettext "Can't connect to \$uri. Skipping."
    echo
    return 1
}

# list_guests URI PERSISTENT
# List running guests on URI.
# PERSISTENT argument options:
# --persistent: list only persistent guests
# --transient: list only transient guests
# [none]: list both persistent and transient guests
list_guests() {
    uri=$1
    persistent=$2

    list=$(run_virsh_c "$uri" list --uuid $persistent)
    if [ $? -ne 0 ]; then
        RETVAL=1
        return 1
    fi

    echo $list
}

# guest_name URI UUID
# return name of guest UUID on URI
guest_name() {
    uri=$1
    uuid=$2

    run_virsh "$uri" domname "$uuid" 2>/dev/null
}

# guest_is_on URI UUID
# check if guest UUID on URI is running
# Result is returned by variable "guest_running"
guest_is_on() {
    uri=$1
    uuid=$2

    guest_running=false
    id=$(run_virsh "$uri" domid "$uuid")
    if [ $? -ne 0 ]; then
        RETVAL=1
        return 1
    fi

    [ -n "$id" ] && [ "x$id" != x- ] && guest_running=true
    return 0
}

# started
# Create the startup lock file
started() {
    touch "$VAR_SUBSYS_LIBVIRT_GUESTS"
}

# start
# Start or resume the guests
start() {
    [ -f "$LISTFILE" ] || { started; return 0; }

    if [ "x$ON_BOOT" != xstart ]; then
        gettext "libvirt-guests is configured not to start any guests on boot"
        echo
        rm -f "$LISTFILE"
        started
        return 0
    fi

    isfirst=true
    bypass=
    test "x$BYPASS_CACHE" = x0 || bypass=--bypass-cache
    while read uri list; do
        configured=false
        set -f
        for confuri in $URIS; do
            set +f
            if [ "x$confuri" = "x$uri" ]; then
                configured=true
                break
            fi
        done
        set +f
        if ! "$configured"; then
            eval_gettext "Ignoring guests on \$uri URI"; echo
            continue
        fi

        test_connect "$uri" || continue

        eval_gettext "Resuming guests on \$uri URI..."; echo
        for guest in $list; do
            name=$(guest_name "$uri" "$guest")
            eval_gettext "Resuming guest \$name: "
            if guest_is_on "$uri" "$guest"; then
                if "$guest_running"; then
                    gettext "already active"; echo
                else
                    if "$isfirst"; then
                        isfirst=false
                    else
                        sleep $START_DELAY
                    fi
                    retval run_virsh "$uri" start $bypass "$name" \
                        >/dev/null && \
                    gettext "done"; echo
                fi
            fi
        done
    done <"$LISTFILE"

    rm -f "$LISTFILE"
    started
}

# suspend_guest URI GUEST
# Do a managed save on a GUEST on URI. This function returns after the guest
# was saved.
suspend_guest()
{
    uri=$1
    guest=$2

    name=$(guest_name "$uri" "$guest")
    label=$(eval_gettext "Suspending \$name: ")
    bypass=
    slept=0
    test "x$BYPASS_CACHE" = x0 || bypass=--bypass-cache
    printf '%s...\n' "$label"
    run_virsh "$uri" managedsave $bypass "$guest" >/dev/null &
    virsh_pid=$!
    while true; do
        sleep 1
        kill -0 "$virsh_pid" >/dev/null 2>&1 || break

        slept=$(($slept + 1))
        if [ $(($slept % 5)) -eq 0 ]; then
            progress=$(run_virsh_c "$uri" domjobinfo "$guest" 2>/dev/null | \
                    awk '/^Data processed:/{print $3, $4}')
            if [ -n "$progress" ]; then
                printf '%s%s\n' "$label" "$progress"
            else
                printf '%s%s\n' "$label" "..."
            fi
        fi
    done
    retval wait "$virsh_pid" && printf '%s%s\n' "$label" "$(gettext "done")"
}

# shutdown_guest URI GUEST
# Start an ACPI shutdown of GUEST on URI. This function returns after the guest
# was successfully shutdown or the timeout defined by $SHUTDOWN_TIMEOUT expired.
shutdown_guest()
{
    uri=$1
    guest=$2

    name=$(guest_name "$uri" "$guest")
    eval_gettext "Starting shutdown on guest: \$name"
    echo
    retval run_virsh "$uri" shutdown "$guest" >/dev/null || return
    timeout=$SHUTDOWN_TIMEOUT
    check_timeout=false
    if [ $timeout -gt 0 ]; then
        check_timeout=true
        format=$(eval_gettext "Waiting for guest %s to shut down, %d seconds left\n")
    else
        slept=0
        format=$(eval_gettext "Waiting for guest %s to shut down\n")
    fi
    while ! $check_timeout || [ "$timeout" -gt 0 ]; do
        sleep 1
        guest_is_on "$uri" "$guest" || return
        "$guest_running" || break

        if $check_timeout; then
            if [ $(($timeout % 5)) -eq 0 ]; then
                printf "$format" "$name" "$timeout"
            fi
            timeout=$(($timeout - 1))
        else
            slept=$(($slept + 1))
            if [ $(($slept % 5)) -eq 0 ]; then
                printf "$format" "$name"
            fi
        fi
    done

    if guest_is_on "$uri" "$guest"; then
        if "$guest_running"; then
            eval_gettext "Shutdown of guest \$name failed to complete in time."
        else
            eval_gettext "Shutdown of guest \$name complete."
        fi
        echo
    fi
}

# shutdown_guest_async URI GUEST
# Start a ACPI shutdown of GUEST on URI. This function returns after the command
# was issued to libvirt to allow parallel shutdown.
shutdown_guest_async()
{
    uri=$1
    guest=$2

    name=$(guest_name "$uri" "$guest")
    eval_gettext "Starting shutdown on guest: \$name"
    echo
    retval run_virsh "$uri" shutdown "$guest" > /dev/null
}

# guest_count GUEST_LIST
# Returns number of guests in GUEST_LIST
guest_count()
{
    set -- $1
    echo $#
}

# check_guests_shutdown URI GUESTS
# check if shutdown is complete on guests in "GUESTS" and returns only
# guests that are still shutting down
check_guests_shutdown()
{
    uri=$1
    guests=$2

    guests_up=
    for guest in $guests; do
        if ! guest_is_on "$uri" "$guest" >/dev/null 2>&1; then
            eval_gettext "Failed to determine state of guest: \$guest. Not tracking it anymore."
            echo
            continue
        fi
        if "$guest_running"; then
            guests_up="$guests_up $guest"
        fi
    done
    echo "$guests_up"
}

# print_guests_shutdown URI BEFORE AFTER
# Checks for differences in the lists BEFORE and AFTER and prints
# a shutdown complete notice for guests that have finished
print_guests_shutdown()
{
    uri=$1
    before=$2
    after=$3

    for guest in $before; do
        case " $after " in
            *" $guest "*) continue;;
        esac

        name=$(guest_name "$uri" "$guest")
        eval_gettext "Shutdown of guest \$name complete."
        echo
    done
}

# shutdown_guests_parallel URI GUESTS
# Shutdown guests GUESTS on machine URI in parallel
shutdown_guests_parallel()
{
    uri=$1
    guests=$2

    on_shutdown=
    check_timeout=false
    timeout=$SHUTDOWN_TIMEOUT
    if [ $timeout -gt 0 ]; then
        check_timeout=true
        format=$(eval_gettext "Waiting for %d guests to shut down, %d seconds left\n")
    else
        slept=0
        format=$(eval_gettext "Waiting for %d guests to shut down\n")
    fi
    while [ -n "$on_shutdown" ] || [ -n "$guests" ]; do
        while [ -n "$guests" ] &&
              [ $(guest_count "$on_shutdown") -lt "$PARALLEL_SHUTDOWN" ]; do
            set -- $guests
            guest=$1
            shift
            guests=$*
            shutdown_guest_async "$uri" "$guest"
            on_shutdown="$on_shutdown $guest"
        done
        sleep 1

        set -- $guests
        guestcount=$#
        set -- $on_shutdown
        shutdowncount=$#

        if $check_timeout; then
            if [ $(($timeout % 5)) -eq 0 ]; then
                printf "$format" $(($guestcount + $shutdowncount)) "$timeout"
            fi
            timeout=$(($timeout - 1))
            if [ $timeout -le 0 ]; then
                eval_gettext "Timeout expired while shutting down domains"; echo
                RETVAL=1
                return
            fi
        else
            slept=$(($slept + 1))
            if [ $(($slept % 5)) -eq 0 ]; then
                printf "$format" $(($guestcount + $shutdowncount))
            fi
        fi

        on_shutdown_prev=$on_shutdown
        on_shutdown=$(check_guests_shutdown "$uri" "$on_shutdown")
        print_guests_shutdown "$uri" "$on_shutdown_prev" "$on_shutdown"
    done
}

# stop
# Shutdown or save guests on the configured uris
stop() {
    # last stop was not followed by start
    [ -f "$LISTFILE" ] && return 0

    suspending=true
    if [ "x$ON_SHUTDOWN" = xshutdown ]; then
        suspending=false
        if [ $SHUTDOWN_TIMEOUT -lt 0 ]; then
            gettext "SHUTDOWN_TIMEOUT must be equal or greater than 0"
            echo
            RETVAL=6
            return
        fi
    fi

    : >"$LISTFILE"
    set -f
    for uri in $URIS; do
        set +f

        test_connect "$uri" || continue

        eval_gettext "Running guests on \$uri URI: "

        list=$(list_guests "$uri")
        if [ $? -eq 0 ]; then
            empty=true
            for uuid in $list; do
                "$empty" || printf ", "
                printf %s "$(guest_name "$uri" "$uuid")"
                empty=false
            done

            if "$empty"; then
                gettext "no running guests."
            fi
            echo
        fi

        if "$suspending"; then
            transient=$(list_guests "$uri" "--transient")
            if [ $? -eq 0 ]; then
                empty=true
                for uuid in $transient; do
                    if "$empty"; then
                        eval_gettext "Not suspending transient guests on URI: \$uri: "
                        empty=false
                    else
                        printf ", "
                    fi
                    printf %s "$(guest_name "$uri" "$uuid")"
                done
                echo
                # reload domain list to contain only persistent guests
                list=$(list_guests "$uri" "--persistent")
                if [ $? -ne 0 ]; then
                    eval_gettext "Failed to list persistent guests on \$uri"
                    echo
                    RETVAL=1
                    set +f
                    return
                fi
            else
                gettext "Failed to list transient guests"
                echo
                RETVAL=1
                set +f
                return
            fi
        fi

        if [ -n "$list" ]; then
            echo "$uri" "$list" >>"$LISTFILE"
        fi
    done
    set +f

    if [ -s "$LISTFILE" ]; then
        while read uri list; do
            if "$suspending"; then
                eval_gettext "Suspending guests on \$uri URI..."; echo
            else
                eval_gettext "Shutting down guests on \$uri URI..."; echo
            fi

            if [ "$PARALLEL_SHUTDOWN" -gt 1 ] &&
               ! "$suspending"; then
                shutdown_guests_parallel "$uri" "$list"
            else
                for guest in $list; do
                    if "$suspending"; then
                        suspend_guest "$uri" "$guest"
                    else
                        shutdown_guest "$uri" "$guest"
                    fi
                done
            fi
        done <"$LISTFILE"
    else
        rm -f "$LISTFILE"
    fi

    rm -f "$VAR_SUBSYS_LIBVIRT_GUESTS"
}

# gueststatus
# List status of guests
gueststatus() {
    set -f
    for uri in $URIS; do
        set +f
        echo "* $uri URI:"
        retval run_virsh "$uri" list || echo
    done
    set +f
}

# rh_status
# Display current status: whether saved state exists, and whether start
# has been executed.  We cannot use status() from the functions library,
# since there is no external daemon process matching this init script.
rh_status() {
    if [ -f "$LISTFILE" ]; then
        gettext "stopped, with saved guests"; echo
        RETVAL=3
    else
        if [ -f "$VAR_SUBSYS_LIBVIRT_GUESTS" ]; then
            gettext "started"; echo
            RETVAL=0
        else
            gettext "stopped, with no saved guests"; echo
            RETVAL=3
        fi
    fi
}

# usage [val]
# Display usage string, then exit with VAL (defaults to 2).
usage() {
    program_name=$0
    eval_gettext "Usage: \$program_name {start|stop|status|restart|"\
"condrestart|try-restart|reload|force-reload|gueststatus|shutdown}"; echo
    exit ${1-2}
}

# See how we were called.
if test $# != 1; then
    usage
fi
case "$1" in
    --help)
        usage 0
        ;;
    start|stop|gueststatus)
        "$1"
        ;;
    restart)
        stop && start
        ;;
    condrestart|try-restart)
        [ -f "$VAR_SUBSYS_LIBVIRT_GUESTS" ] && stop && start
        ;;
    reload|force-reload)
        # Nothing to do; we reread configuration on each invocation
        ;;
    status)
        rh_status
        ;;
    shutdown)
        ON_SHUTDOWN=shutdown
        stop
        ;;
    *)
        usage
        ;;
esac
exit $RETVAL
