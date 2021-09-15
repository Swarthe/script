#!/usr/bin/env bash
#
# backup: Synchronise the filesystem to an external location with rsync,
#         assuming FHS compliance
#
# Copyright (c) 2021 Emil Overbeck <https://github.com/Swarthe>
#
# Subject to the MIT License. See LICENSE.txt for more information.
#
# This software is IN DEVELOPMENT and you may PERMANENTLY lose data if you are
# not careful. Please report bugs at <https://github.com/Swarthe/utility>.
#

#
# User I/O functions and variables
#

readonly normal="$(tput sgr0)"
readonly bold="$(tput bold)"
readonly bold_red="${bold}$(tput setaf 1)"
readonly bold_yellow="${bold}$(tput setaf 3)"
readonly bold_blue="${bold}$(tput setaf 4)"
readonly bold_cyan="${bold}$(tput setaf 6)"

usage ()
{
    cat << EOF
Usage: backup [OPTION]... [-t] [TARGET]
Synchronise the filesystem to an external location.
Unless manually set, automatically determine the target.

Options:
  -v    use verbose output
  -l    log to file instead of stdout (implies '-v')
  -t    specify target for the backup
  -s    skip all interactive prompts (use at your own peril)
  -h    display this help text

Example: backup -lt /mnt/backup/

Note: Export the 'BACKUP_TARGET' variable to set the default target.
EOF
}

err ()
{
    printf '%berror:%b %b\n' "$bold_red" "$normal" "$*" >&2
}

warn ()
{
    printf '%bwarn:%b %b\n' "$bold_yellow" "$normal" "$*"
}

info ()
{
    printf '%binfo:%b %b\n' "$bold_blue" "$normal" "$*"
}

ask ()
{
    local confirm
    until [ "$confirm" = "y" -o "$confirm" = "n" ]; do
        printf '%b::%b %b [y/n] ' "$bold_cyan" "$normal" "$*"
        read -r confirm
    done
    [ "$confirm" != "y" ] && return 1 || return 0
}

#
# Handle options
#

while getopts :hvlist: opt; do
    case "${opt}" in
    h)
        usage && exit
        ;;
    v)
        verbose=1
        ;;
    l)
        log=1
        ;;
    i)
        interact=1
        ;;
    t)
        target="$(realpath "$OPTARG")"
        ;;
    s)
        skip_interact=1
        ;;
    :)
        err "Option '$OPTARG' requires an argument"
        printf '%s\n' "Try 'backup -h' for more information."
        exit 1
        ;;
    \?)
        err "Invalid option '$OPTARG'"
        printf '%s\n' "Try 'backup -h' for more information."
        exit 1
        ;;
    esac
done

#
# Attempt to determine target and related data if needed
#

latest_source="$(df --output=source | tail -n 1)"

if [ -z "$target" ]; then
    if [ "$BACKUP_TARGET" ]; then
        target="$(realpath "$BACKUP_TARGET")"
    # use latest mounted real filesystem
    elif [ -e "$latest_source" ]; then
        target="$(realpath "$latest_source")"
    else
        err "Could not determine a suitable target"
        printf '%s\n' "Try 'backup -h' for more information."
        exit 1
    fi
fi

[ -e "$target" ] \
    && target_source="$(df --output=source "$target" | tail -n 1)"

[ "$target_source" ] \
    && target_target="$(df --output=target "$target" | tail -n 1)"

[ "$target_source" ] \
    && target_model="$(lsblk -no MODEL /dev/"$(lsblk -no PKNAME "$target_source")")"

#n_inode=$(df --output=iused / | tail -n 1)

#
# Run checks
#

check_exclude ()
{
    # succeed if target is in excluded dirs
    # get first element in path (ugly)
    case "$(sed 's/\/[^/]*//2g' <<< "$target")" in
    /dev|/proc|/sys|/tmp|/run|/mnt)
        return
        ;;
    esac

    return 1
}

check_root ()
{
    # succeed if root
    [ "$target_target" = "/" ]
}

check_space ()
{
    # succeed if not enough space
    [ $(df --output=used -k / | tail -n 1) \
    -gt $(df --output=size -k "$target" | tail -n 1) ]
}

# a recursive backup would be extremely dangerous for the filesystem
if ! check_exclude; then
    err "Recursive backups are not permitted"
    printf '%s\n' "The target may be mounted to a non-standard location."
    exit 2
fi

if [ $(id -u) != 0 ]; then
    warn "We do not have root privileges"
fi

if [ -d "$target" -a -w "$target" -a "$target_model" ]; then
    if check_root; then
        warn "Target drive '$target_model' is the root drive"
        target_is_root=1
    fi

    if check_space; then
        warn "Target drive '$target_model' has insufficient free space"
    fi
elif [ -d "$target" -a "$target_model" ]; then
    warn "Target '$target' is inaccessible"
elif [ -e "$target" ]; then
    warn "Target '$target' is invalid"
else
    warn "Target '$target' does not exist"
fi

#
# Confirm or announce target
#

if [ -z "$skip_interact" ]; then
    if [ "$target_model" ]; then
        ask "Backup to '$target' on '$target_model'?" \
            || exit 0
    else
        ask "Backup to '$target'?" \
            || exit 0
    fi
else
    if [ "$target_model" ]; then
        info "Target is '$target' on '$target_model'" \
            || exit 0
    else
        info "Target is '$target'" \
            || exit 0
    fi
fi

#
# Run backup
#

readonly clear_line="$(tput cr && tput el 1)"

syncr ()
{
    if [ -z "$verbose" -a -z "$log" ]; then
        rsync -aHAXE --info=progress2 --delete / \
        --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/lost+found","/swapfile"} \
        "$target"
    else
        rsync -aHAXEv --delete / \
        --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/lost+found","/swapfile"} \
        "$target"
    fi
}

clean ()
{
    if [ -z "$skip_interact" -a -z "$target_is_root" -a "$target_model" ]; then
        ask "Unmount target drive '$target_model' at '$target_target'?" \
            || exit 0
        umount "$target_target"
    fi
}

if [ -z "$log" ]; then
    syncr && clean
else
    log_file="$(realpath backup.log)"

    if [ -w . ]; then
        syncr &> "$log_file" &
        rsync_pid=$!
        info "Log file is '$log_file'"

        file_count ()
        {
            wc -l < $log_file
        }
    else
        syncr &> /dev/null &
        rsync_pid=$!
        err "Could not create log file"

        file_count ()
        {
            printf '%s' "?"
        }
    fi

    while kill -0 $rsync_pid 2> /dev/null; do
        for i in '   ' '.  ' '.. ' '...'; do
            # the escape code resets the line
            printf '%b%binfo:%b %s %s'          \
            "$clear_line"                       \
            "$bold_blue"                        \
            "$normal"                           \
            "Backup in progress$i"              \
            "($(file_count) files copied)"
            sleep 0.5
        done
    done

    printf '%b' "\n"

    if wait $rsync_pid; then
        info "Backup successful" && clean
    else
        err "Backup failed"
        [ -e $log_file ] \
            && printf '%s\n' "See '$log_file' for more information."
    fi
fi