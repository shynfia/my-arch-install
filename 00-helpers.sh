#!/usr/bin/bash
 
green="\033[0;32m"
bold_white="\033[1;37m"
reset="\033[0m"
 
log() {
    echo -e "\n${green}=>${reset} ${bold_white}${*}${reset}"
}
 
info() {
    echo -e "${bold_white}~ ${*}${reset}"
}
 
# Either do a dry run or run the actual command
# Requires a numeric variable dry_run to be defined
drynt() {
    command="$@"
    if [[ "$dry_run" -eq 0 ]]; then
        eval "$command"
    else
        echo "$command"
    fi
}
 
self_clean() {
    drynt rm -- "$0"
}
