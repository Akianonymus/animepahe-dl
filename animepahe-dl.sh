#!/usr/bin/env bash
#
# Download anime from animepahe using CLI
#
#/ Usage:
#/   ./animepahe-dl.sh [-s <anime_slug>] [-e <episode_num1,num2...>]
#/
#/ Options:
#/   -s <slug>          Anime slug, can be found in $_ANIME_LIST_FILE
#/   -e <num1,num2...>  Optional, episode number to download
#/                      multiple episode numbers seperated by ","
#/   -h | --help        Display this help message

set -e
set -u

usage() {
    printf "%b\n" "$(grep '^#/' "$0" | cut -c4-)" && exit 1
}

set_var() {
    _CURL=$(command -v curl)
    _JQ=$(command -v jq)
    _PUP=$(command -v pup)
    _FZF=$(command -v fzf)
    _NODE=$(command -v node)
    _CHROME=$(command -v chromium)

    _HOST="https://animepahe.com"
    _ANIME_URL="$_HOST/anime"
    _API_URL="$_HOST/api"

    _SCRIPT_PATH=$(dirname "$0")
    _ANIME_LIST_FILE="$_SCRIPT_PATH/anime.list"
    _BYPASS_CF_SCRIPT="$_SCRIPT_PATH/bin/getCFcookie.js"
    _USER_AGENT="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$($_CHROME --version | awk '{print $2}') Safari/537.36"
    _CF_FILE="$_SCRIPT_PATH/cf_clearance"
    _SOURCE_FILE=".source.json"
}

set_args() {
    expr "$*" : ".*--help" > /dev/null && usage
    while getopts ":hs:e:" opt; do
        case $opt in
            s)
                _ANIME_SLUG="$OPTARG"
                ;;
            e)
                _ANIME_EPISODE="$OPTARG"
                ;;
            h)
                usage
                ;;
            \?)
                echo "[ERROR] Invalid option: -$OPTARG" >&2
                usage
                ;;
        esac
    done
}

download_anime_list() {
    $_CURL -sS "$_ANIME_URL" \
        | $_PUP 'div a' \
        | grep "/anime/" \
        | sed -E 's/.*anime\//[/;s/" title="/] /;s/\">//' \
        > "$_ANIME_LIST_FILE"
}

get_token_and_cookie() {
    # $1: download link
    local l cf j t c

    l=$(echo "$1" | sed -E 's/.cx\/e/.cx\/f/')

    if [[ "$(is_cf_expired)" == "yes" ]]; then
        cf=$(get_cf_clearance "$l" | tee "$_CF_FILE")
    else
        cf=$(cat "$_CF_FILE")
    fi

    if [[ -z "$cf" ]]; then
        echo "[ERROR] Cannot fetch cf_clearance from $l!" >&2 && exit 1
    fi

    h=$($_CURL -sS -c - "$l" \
        --header "User-Agent: $_USER_AGENT"  \
        --header "cookie: cf_clearance=$cf")

    j=$(grep 'eval' <<< "$h" | sed -E 's/eval/console.log/')

    t=$($_NODE -e "$j" 2>&1 \
        | grep '_token' \
        | sed -E "s/.*value=\"//" \
        | awk -F'"' '{print $1}')

    c=$(grep '_session' <<< "$h" | awk '{print $NF}')

    echo "$t $c"
}

get_anime_id() {
    # $1: anime slug
    $_CURL -sS "$_ANIME_URL/$1" \
        | grep getJSON \
        | sed -E 's/.*id=//' \
        | awk -F '&' '{print $1}'
}

download_source() {
    mkdir -p "$_SCRIPT_PATH/$_ANIME_NAME"
    $_CURL -sS "${_API_URL}?m=release&id=$(get_anime_id "$_ANIME_SLUG")&sort=episode_asc" > "$_SCRIPT_PATH/$_ANIME_NAME/$_SOURCE_FILE"
}

get_episode_link() {
    # $1: episode number
    local i s
    i=$($_JQ -r '.data[] | select((.episode | tonumber) == ($num | tonumber)) | .anime_id' --arg num "$1" < "$_SCRIPT_PATH/$_ANIME_NAME/$_SOURCE_FILE")
    s=$($_JQ -r '.data[] | select((.episode | tonumber) == ($num | tonumber)) | .session' --arg num "$1" < "$_SCRIPT_PATH/$_ANIME_NAME/$_SOURCE_FILE")
    if [[ "$i" == "" ]]; then
        echo "[ERROR] Episode not found!" >&2 && exit 1
    else
        $_CURL -sS "${_API_URL}?m=embed&id=${i}&session=${s}&p=kwik" \
            | $_JQ -r '.data[][].url' \
            | tail -1
    fi
}

get_media_link() {
    # $1: episode link
    # $2: token
    # $3: cookie
    local l o
    l=$(echo "$1" | sed -E 's/.cx\/e/.cx\/d/')
    o=$($_CURL -sS "$l" \
        -H "Referer: $l" \
        -H "Cookie: kwik_session=$3" \
        --data "_token=$2" \
        | $_PUP 'a attr{href}')

    if [[ -z "$o" ]]; then
        echo "[ERROR] Cannot fetch media download link! Try again." >&2
        rm -rf "$_CF_FILE"
        exit 1
    fi

    echo "$o"
}

download_episodes() {
    # $1: episode number string
    if [[ "$1" == *","* ]]; then
        IFS=","
        read -ra ADDR <<< "$1"
        for e in "${ADDR[@]}"; do
            download_episode "$e"
        done
    else
        download_episode "$1"
    fi
}

get_cf_clearance() {
    # $1: url
    echo "[INFO] Wait for solving reCAPTCHA to visit $1..." >&2
    $_BYPASS_CF_SCRIPT -u "$1" -a "$_USER_AGENT" -p "$_CHROME" -s \
        | $_JQ -r '.[] | select(.name == "cf_clearance") | .value'
}

is_cf_expired() {
    local o
    o="yes"

    if [[ -f "$_CF_FILE" && -s "$_CF_FILE" ]]; then
        local d n
        d=$(date -d "$(date -r "$_CF_FILE") +1 days" +%s)
        n=$(date +%s)

        if [[ "$n" -lt "$d" ]]; then
            o="no"
        fi
    fi

    echo "$o"
}

download_episode() {
    # $1: episode number
    local l s t c m

    l=$(get_episode_link "$1")
    if [[ "$l" != *"/"* ]]; then
        echo "[ERROR] Wrong download link or episode not found!" >&2 && exit 1
    fi

    s=$(get_token_and_cookie "$l")
    t=$(echo "$s" | awk '{print $1}')
    c=$(echo "$s" | awk '{print $NF}')
    m=$(get_media_link "$l" "$t" "$c")

    echo "[INFO] Downloading Episode $1..." >&2
    $_CURL -L -g -o "$_SCRIPT_PATH/${_ANIME_NAME}/${1}.mp4" "$m"
}

select_episodes_to_download() {
    $_JQ -r '.data[] | "[\(.episode | tonumber)] E\(.episode | tonumber) \(.created_at)"' < "$_SCRIPT_PATH/$_ANIME_NAME/$_SOURCE_FILE" >&2
    echo -n "Which episode(s) to downolad: " >&2
    read -r s
    echo "$s"
}

main() {
    set_args "$@"
    set_var

    if [[ -z "${_ANIME_SLUG:-}" ]]; then
        download_anime_list
        [[ ! -f "$_ANIME_LIST_FILE" ]] && (echo "[ERROR] $_ANIME_LIST_FILE not found!" && exit 1)
        _ANIME_SLUG=$($_FZF < "$_ANIME_LIST_FILE" | awk -F']' '{print $1}' | sed -E 's/^\[//')
    fi

    [[ "$_ANIME_SLUG" == "" ]] && (echo "[ERROR] Anime slug not found!"; exit 1)
    _ANIME_NAME=$(grep "$_ANIME_SLUG" "$_ANIME_LIST_FILE" | awk -F '] ' '{print $2}' | sed -E 's/\//_/g')

    [[ "$_ANIME_NAME" == "" ]] && (echo "[ERROR] Anime name not found! Try again."; download_anime_list; exit 1)

    download_source

    [[ -z "${_ANIME_EPISODE:-}" ]] && _ANIME_EPISODE=$(select_episodes_to_download)
    download_episodes "$_ANIME_EPISODE"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
