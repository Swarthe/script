#!/usr/bin/env bash
#
# ydl: Download video or audio media from the internet with metadata in an
#      organised fashion using youtube-dl
#
# Copyright (c) 2021 Emil Overbeck <https://github.com/Swarthe>
#
# Subject to the MIT License. See LICENSE.txt for more information.
#

# TODO
#
# maybe add this as feature:
#
# Cool example command for audio playlists from YouTube ' - Topic' channels
# which don't have artists name in title:
#
# youtube-dl --add-header 'Cookie:' --playlist-start $start --playlist-end \
# $end -xo "%(creator)s - %(title)s.%(ext)s" "$url"
#
#
# maybe maybe add env variables for default target (transient for us) and
# creator setting and other
#
# maybe add option for youtube-dl 'ytsearch'
#

#
# User I/O functions and variables
#

readonly normal="$(tput sgr0)"
readonly bold="$(tput bold)"
readonly bold_red="${bold}$(tput setaf 1)"

usage ()
{
    cat << EOF
Usage: ydl [OPTION]... [-t] [TARGET] [URL]...
Download video or audio media form the internet.

Options:
  -a    download media as audio
  -t    specify the target directory for the download
  -c    prepend the creator's name to the filename
  -g    specify 'on' to enable graphical user I/O; specify 'off' to disable
          (overrides '\$UTILITY_GRAPHICAL')
  -h    display this help text

Example: ydl -ct ~/video [URL]

Environment variables:
  UTILITY_GRAPHICAL     set to '1' to enable graphical user I/O

Note: Media is downloaded as video in current working directory by default.
EOF
}

err ()
{
    printf '%berror:%b %s\n' "$bold_red" "$normal" "$*" >&2
}

gerr ()
{
    notify-send -i /usr/share/icons/Papirus-Dark/32x32/apps/youtube-dl.svg \
    -u critical 'ydl' "$*"
}

ginfo ()
{
    notify-send -i /usr/share/icons/Papirus-Dark/32x32/apps/youtube-dl.svg \
    'ydl' "$*"
}

#
# Handle options
#

while getopts :ht:acg: opt; do
    case "${opt}" in
    h)
        usage; exit
        ;;
    t)
        # add leading slash to avoid breaking youtube-dl
        target="$(realpath "$OPTARG")/"
        ;;
    a)
        # youtube-dl cannot embed subtitles in audio files
        format='-x'
        ;;
    c)
        creator="%(creator)s - "
        ;;
    g)
        case "$OPTARG" in
        on)
            graphical=1
            ;;
        off)
            graphical=0
            ;;
        *)
            err "Invalid argument '$OPTARG' for option 'g'"
            printf '%s\n' "Try 'ydl -h' for more information."
            exit 1
            ;;
        esac
        ;;
    \?)
        err "Invalid option '$OPTARG'"
        printf '%s\n' "Try 'ydl -h' for more information."
        exit 1
        ;;
    esac
done

shift $((OPTIND-1))
args=("$@")

# Determine whether or not to use graphical output
if [ -z $graphical ] && [ "$graphical" != 0 ]; then
    [ "$UTILITY_GRAPHICAL" = 1 ] && graphical=1
else
    [ "$graphical" = 0 ] && graphical=''
fi

# default youtube-dl options for video
if [ -z "$format" ]; then
    format='--embed-subs --all-subs'
fi

#
# Run the download
#

if [ "$args" ]; then
    if youtube-dl --embed-thumbnail --add-metadata $format \
       --add-header 'Cookie:' -io "${target}${creator}%(title)s.%(ext)s" \
       "${args[@]}"; then
        [ $graphical ] && ginfo "Download successful"
    else
        [ $graphical ] && gerr "Download failed"
        exit 2
    fi
else
    err "Missing URL"
    printf '%s\n' "Try 'ydl -h' for more information."
    exit 1
fi
