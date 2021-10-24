#!/usr/bin/env bash
#
# backup: Synchronise the filesystem to or from an external location using
#         rsync, assuming FHS compliance
#
# If using the BACKUP_TARGET or BACKUP_LINK_DIR environment variables, you can
# configure sudo to preserve them by adding the following to your sudoers file:
#
#   Defaults env_keep += "BACKUP_TARGET BACKUP_LINK_DIR"
#
# Copyright (c) 2021 Emil Overbeck <https://github.com/Swarthe>
#
# Subject to the MIT License. See LICENSE.txt for more information.
#
# This software is IN DEVELOPMENT and you may PERMANENTLY lose data if you are
# not careful. Please report bugs at <https://github.com/Swarthe/utility>.
#

# TODO
#
# maybe add possibility for true incremental backups with --link-dest
#

#
# User I/O functions and variables
#

readonly normal="$(tput sgr0)"
readonly clear_line="$(tput cr && tput el 1)"
readonly bold="$(tput bold)"
readonly bold_red="${bold}$(tput setaf 1)"
readonly bold_yellow="${bold}$(tput setaf 3)"
readonly bold_blue="${bold}$(tput setaf 4)"
readonly bold_cyan="${bold}$(tput setaf 6)"

usage ()
{
    cat << EOF
Usage: backup [OPTION]... [-s] [VALUE] [-t] [TARGET]
Synchronise the filesystem to or from an external location.

Options:
  -v    use verbose output
  -l    log to a file instead of stdout (implies '-v')
  -t    specify the backup target location (overrides '\$BACKUP_TARGET')
  -L    specify directory from which to hardlink identical files to target;
         useful for saving disk space with multiple backups on one drive
         (overrides '\$BACKUP_LINK_DIR')
  -o    specify the backup origin location (useful to recover backups)
  -s    specify what safety features to skip (use at your own peril); 'prompt'
          to skip prompts, 'check' to skip checks, 'all' to skip everything
  -h    display this help text

Example: backup -lt /mnt/backup/

Environment variables:
  BACKUP_TARGET         set the backup target location
  BACKUP_LINK_DIR       set the directory for '-L'

Note: Unless manually set, we attempt to automatically determine the target.
EOF
}

err ()
{
    printf '%berror:%b %s\n' "$bold_red" "$normal" "$*" >&2
}

warn ()
{
    printf '%bwarn:%b %s\n' "$bold_yellow" "$normal" "$*"
}

info ()
{
    printf '%binfo:%b %s\n' "$bold_blue" "$normal" "$*"
}

ask ()
{
    local confirm

    until [ "$confirm" = "y" -o "$confirm" = "n" ]; do
        printf '%b::%b %s [y/n] ' "$bold_cyan" "$normal" "$*"
        read -r confirm
    done

    if [ "$confirm" = "y" ]; then
        return 0
    else
        return 1
    fi
}

#
# Handle options
#

while getopts :hvlit:L:o:s: opt; do
    case "${opt}" in
    h)
        usage; exit
        ;;
    v)
        verbose=1
        ;;
    l)
        log=1
        ;;
    t)
        target="$(realpath "$OPTARG")"
        ;;
    L)
        link_dir="$(realpath "$OPTARG")"
        ;;
    o)
        origin="$(realpath "$OPTARG")"
        ;;
    s)
        case "$OPTARG" in
        prompt)
            skip_interact=1
            ;;
        check)
            skip_check=1
            ;;
        all)
            skip_interact=1; skip_check=1
            ;;
        *)
            err "Invalid argument '$OPTARG' for option 's'"
            printf '%s\n' "Try 'backup -h' for more information."
            exit 1
            ;;
        esac
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

shift $((OPTIND-1))
args=("$@")

# do not permit extra arguments
if [ "$args" ]; then
    for c in "${args[@]}"; do
         err "Invalid argument '$c'"
    done

    printf '%s\n' "Try 'backup -h' for more information."
    exit 1
fi

# Determine link directory
if [ -z "$link_dir" ]; then
    [ "$BACKUP_LINK_DIR" ] && link_dir="$(realpath "$BACKUP_LINK_DIR")"
fi

# Set up rsync options
[ "$link_dir" ] && rsync_opt+="--link-dest="$link_dir" "

if [ "$verbose" -o "$log" ]; then
    # verbose
    rsync_opt+="-v "
else
    # progress indicator
    rsync_opt+="--info=progress2 "
fi

# Backup from root by default
[ -z "$origin" ] && origin='/'

#
# Collect data
#

if [ -z "$target" ]; then
    if [ "$BACKUP_TARGET" ]; then
        target="$(realpath "$BACKUP_TARGET")"
    # use latest mounted real filesystem
    elif [ -e "$(df --output=source | tail -n 1)" ]; then
        target="$(realpath "$(df --output=source | tail -n 1)")"
    else
        err "Could not determine a suitable target"
        printf '%s\n' "Try 'backup -h' for more information."
        exit 1
    fi
fi

if [ -e "$target" ]; then
    target_source="$(df --output=source "$target" | tail -n 1)"
fi

if [ "$target_source" ]; then
    target_target="$(df --output=target "$target" | tail -n 1)"
    target_model="$(lsblk -no MODEL /dev/"$(lsblk -no PKNAME "$target_source")")"
fi

if [ -e "$origin" ]; then
    origin_source="$(df --output=source "$origin" | tail -n 1)"
fi

if [ "$origin_source" ]; then
    origin_target="$(df --output=target "$origin" | tail -n 1)"
    origin_model="$(lsblk -no MODEL /dev/"$(lsblk -no PKNAME "$origin_source")")"
fi

#n_inode=$(df --output=iused / | tail -n 1)

#
# Run checks
#

if [ -z $skip_check ]; then
    check_exclude ()
    {
        # succeed if target is in excluded dirs
        # get first element in path (ugly)
        # it is useless if the origin is on a different drive as it could never
        # be recursive
        if [ "$origin" != '/' ]; then
            case "$(sed 's/\/[^/]*//2g' <<< "$target")" in
            /dev|/proc|/sys|/tmp|/run|/mnt)
                return
                ;;
            esac
        fi

        return 1
    }

    check_same_fs ()
    {
        # succeed if same filesystem
        [ "$target_target" = "$origin_target" ]
    }

    check_space ()
    {
        # succeed if not enough space
        [ $(df --output=used -k "$origin" | tail -n 1) \
        -gt $(df --output=size -k "$target" | tail -n 1) ]
    }

    # a recursive backup would be extremely dangerous for the filesystem
    if ! check_exclude; then
        err "Recursive backups are not permitted"
        printf '%s\n' "The target may be mounted to a non-standard location."
        recursive_backup=1
    fi

    if [ $(id -u) != 0 ]; then
        warn "We do not have root privileges"
    fi

    if [ -d "$target" -a "$target_model" ]; then
        if [ -w "$target" ]; then
            if [ -r "$origin" ]; then
                if check_same_fs; then
                    warn "Target and origin are on the same drive; '$target_model'"
                    same_fs=1
                fi

                if check_space; then
                    warn "Target drive '$target_model' has insufficient free space"
                fi
            elif [ -e "$origin" ]; then
                warn "Origin '$origin' is inaccessible"
            else
                warn "Origin '$origin' does not exist"
            fi
        else
            warn "Target '$target' is inaccessible"
        fi
    elif [ -e "$target" ]; then
        warn "Target '$target' is invalid"
    else
        warn "Target '$target' does not exist"
    fi

    if [ "$link_dir" ]; then
        if ! [ -e "$link_dir" ]; then
            warn "Link directory '$link_dir' does not exist"
            no_link=1
        elif ! [ -r "$link_dir" ]; then
            warn "Link directory '$link_dir' is inaccessible"
            no_link=1
        fi
    fi
fi

#
# Confirm or announce target and related information
#

if [ "$link_dir" ] && [ -z $no_link ]; then
    info "Identical files will be hardlinked from '$link_dir' to '$target'"
fi

if [ $skip_interact ]; then
    [ $recursive_backup ] && exit 2

    if [ "$origin" != '/' ]; then
        if [ "$target_model" ]; then
            info "Target is '$target' on '$target_model'"
        else
            info "Target is '$target'"
        fi
    else
        if [ "$target_model" ] && [ "$origin_model" ]; then
            info "Origin is '$origin' on '$origin_model'; target is '$target' on '$target_model'"
        else
            info "Origin is '$origin'; Target is '$target'"
        fi
    fi
else
    # recursive_backup is never declared if checks are skipped
    if [ $recursive_backup ]; then
        if ask "Exclude '$target' from backup?"; then
            rsync_exclude="$target"
        else
            exit
        fi
    fi

    if [ "$origin" != '/' ]; then
        if [ "$target_model" ]; then
            ask "Backup to '$target' on '$target_model'?" \
                || exit 0
        else
            ask "Backup to '$target'?" \
                || exit 0
        fi
    else
        if [ "$target_model" ] && [ "$origin_model" ]; then
            ask "Backup from '$origin' on '$origin_model to '$target' on '$target_model'?" \
                || exit 0
        else
            ask "Backup from '$origin' to '$target'?" \
                || exit 0
        fi
    fi
fi

#
# Run the backup
#

back ()
{
    # default exclusions should be proper for most cases
    rsync -aHAXE $rsync_opt --delete "$origin" \
    --exclude={"${origin}/dev/*","${origin}/proc/*","${origin}/sys/*","${origin}/tmp/*","${origin}/run/*","${origin}/mnt/*","${origin}/lost+found","${origin}/swapfile","${origin}$rsync_exclude"} \
    "$target"
}

clean ()
{
    if [ -z "$skip_interact" -a -z "$same_fs" ]; then
        if [ "$target_model" ]; then
            ask "Unmount target drive '$target_model' at '$target_target'?" \
                && umount "$target_target"
        elif [ "$origin" != '/' -a "$origin_model" ]; then
            ask "Unmount origin drive '$origin_model' at '$origin_target'?" \
                && umount "$origin_target"
        fi
    fi
}

if [ "$log" ]; then
    log_file="$(realpath backup.log)"

    if [ -w . ]; then
        back &> "$log_file" &
        rsync_pid=$!
        info "Log file is '$log_file'"

        # very approximative and unreliable
        file_count ()
        {
            wc -l < $log_file
        }
    else
        back &> /dev/null &
        rsync_pid=$!
        err "Could not create log file"

        file_count ()
        {
            printf '?'
        }
    fi

    while kill -0 $rsync_pid 2> /dev/null; do
        for c in '   ' '.  ' '.. ' '...'; do
            printf '%b%binfo:%b %s %s'      \
            "$clear_line"                   \
            "$bold_blue"                    \
            "$normal"                       \
            "Backup in progress$c"          \
            "($(file_count) files copied)"
            sleep 0.5
        done
    done

    printf '\n'

    if wait $rsync_pid; then
        info "Backup successful"; clean
        exit
    else
        err "Backup failed"
        [ -e $log_file ] \
            && printf '%s\n' "See '$log_file' for more information."
        exit 3
    fi
else
    if ! back; then
        exit 3
    fi
fi
