#!/bin/bash


# how to use: 
#    parese_toml_with_section file_path section_name key_name
parse_toml_with_section(){
    [[ -f $1 ]] || { echo "$1 is not a file." >&2;return 1;}
    local -n config_array=config
    [[ -n $2 ]] || { echo "pleas pass your interested section name as second variable!";}
    if [[ -n $3 ]]; then 
        key_name="$3"
    else
        echo "pleas pass your interested key name as third variable!";
    fi
    declare -Ag ${!config_array} || return 1
    local line key value section_regex entry_regex interested_section_array
    section_regex="^[[:blank:]]*\[([[:alpha:]_][[:alnum:]/._-]*)\][[:blank:]]*(#.*)?$"
    entry_regex="^[[:blank:]]*([[:alpha:]_][[:alnum:]_]*)[[:blank:]]*=[[:blank:]]*('[^']+'|\"[^\"]+\"|[^#[:blank:]]+)[[:blank:]]*(#.*)*$"
    while read -r line
    do
        [[ -n $line ]] || continue
        [[ $line =~ $section_regex ]] && {
            local -n config_array=${BASH_REMATCH[1]//\./\_} # if section name contains ".", replace it with "_" for naming.
            if [[ ${BASH_REMATCH[1]} =~ $2 ]]; then 
               interested_section_array="$BASH_REMATCH"
            else
               continue 
            fi
            declare -Ag ${!config_array} || return 1
            continue
        }
        [[ $line =~ $entry_regex ]] || continue
        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]#[\'\"]} # strip quotes
        value=${value%[\'\"]}
        config_array["${key}"]="${value}"
    done < "$1"
    declare -n array="${interested_section_array//\./\_}"
    echo ${array[$key_name]}
}

isRollupCellExits(){
    echo $1
    if [[ -n $1 ]]; 
    then
        local tomlconfigfile="$1"
    else
        local tomlconfigfile="/code/godwoken/config.toml"
    fi

    rollup_code_hash=$( parse_toml_with_section "$tomlconfigfile" "chain.rollup_type_script" "code_hash" )
    rollup_hash_type=$( parse_toml_with_section "$tomlconfigfile" "chain.rollup_type_script" "hash_type" )
    rollup_args=$( parse_toml_with_section "$tomlconfigfile" "chain.rollup_type_script" "args" )

    # curl retry on connrefused, considering ECONNREFUSED as a transient error(network issues)
    # connections with ipv6 are not retried because it returns EADDRNOTAVAIL instead of ECONNREFUSED,
    # hence we should use --ipv4
    result=$( echo '{
    "id": 2,
    "jsonrpc": "2.0",
    "method": "get_cells",
    "params": [
        {
            "script": {
                "code_hash": "'${rollup_code_hash}'",
                "hash_type": "'${rollup_hash_type}'",
                "args": "'${rollup_args}'"
            },
            "script_type": "type"
        },
        "asc",
        "0x64"
    ]
    }' \
    | tr -d '\n' \
    | curl --ipv4 --retry 3 --retry-connrefused \
    -H 'content-type: application/json' -d @- \
    http://localhost:8116)

    if [[ $result =~ "block_number" ]]; then
        echo "Rollup cell exits!"
        # 0 equals true
        return 0
    else
        echo "can not found Rollup cell!"
        # 1 equals false
        return 1
    fi
}

# set key value in toml config file
# how to use: set_key_value_in_toml key value your_toml_config_file
set_key_value_in_toml() {
    if [[ -f $3 ]];
    then echo 'found toml file.'
    else
        echo "${3} file not exits, skip this steps."
        return 0
    fi


    local key=${1}
    local value=${2}
    if [ -n $value ]; then
        #echo $value
        local current=$(sed -n -e "s/^\($key = '\)\([^ ']*\)\(.*\)$/\2/p" $3}) # value带单引号
        if [ -n $current ];then
            echo "setting $3 : $key = $value"
            value="$(echo "${value}" | sed 's|[&]|\\&|g')"
            sed -i "s|^[#]*[ ]*${key}\([ ]*\)=.*|${key} = '${value}'|" ${3}
        fi
    fi
}

get_sudt_code_hash_from_lumos_file() {
    if [[ -n $1 ]]; 
    then
        local lumosconfigfile="$1"
    else
        local lumosconfigfile="/code/godwoken-examples/packages/runner/configs/lumos-config.json"
    fi

    echo "$(cat $lumosconfigfile)" | grep -Pzo 'SUDT[\s\S]*CODE_HASH": "\K[^"]*'
}

 
generateSubmodulesEnvFile(){
    File="docker/.manual.build.list.env"
    if [[ -f $File ]]; then
        rm $File 
    fi
    echo "####[mode]" >> $File
    echo MANUAL_BUILD_GODWOKEN=false >> $File
    echo MANUAL_BUILD_WEB3=false >> $File
    echo '' >> $File

    # if submodule folder is not initialized and updated
    if [[ -z "$(ls -A godwoken)" || -z "$(ls -A godwoken-examples)" || -z "$(ls -A godwoken-polyjuice)" || -z "$(ls -A godwoken-web3)" ]]; then
       echo "one or more of submodule folders is Empty, do init and update first."
       git submodule update --init --recursive
    fi

    local -a arr=("godwoken" "godwoken-web3" "godwoken-polyjuice" "godwoken-examples")
    for i in "${arr[@]}"
    do
       # get origin url
       url=$(git config --file .gitmodules --get-regexp "submodule.${i}.path" | 
        awk '{print $2}' | xargs -i git -C {} remote get-url origin)
       # get branch
       branchs=$(git config --file .gitmodules --get-regexp "submodule.${i}.path" | 
        awk '{print $2}' |  xargs -i git -C {} branch -q)
       # get last commit
       commit=$(git config --file .gitmodules --get-regexp "submodule.${i}.path" | 
        awk '{print $2}' | xargs -i git -C {} log --pretty=format:'%h' -n 1 )

       # renameing godwoken-examples => godwoken_examples, 
       # cater for env variable naming rule.
       url_name=$(echo "${i^^}_URL" | tr - _ )
       branch_name=$(echo "${i^^}_BRANCH" | tr - _)
       commit_name=$(echo "${i^^}_COMMIT" | tr - _ )

       echo "####["$i"]" >> $File
       echo "$url_name=$url" >> $File
       echo "$branchs" >> $File
       echo "$commit_name=$commit" >> $File
       echo '' >> $File

       sed -i /HEAD/d $File 
       sed -i "s/[ ]./$branch_name=/" $File
    done
}

update_submodules(){
   # load env from submodule info file
   # use these env varibles to update the desired submodules
   source docker/.manual.build.list.env

   local -a arr=("godwoken" "godwoken-web3" "godwoken-polyjuice" "godwoken-examples")
   for i in "${arr[@]}"
   do
      # set url for submodule
      remote_url_key=$(echo "${i^^}_URL" | tr - _ )
      remote_url_value=$(printf '%s\n' "${!remote_url_key}")
      git submodule set-url -- $i $remote_url_value 

      # set branch for submodule
      branch_key=$(echo "${i^^}_BRANCH" | tr - _ )
      branch_value=$(printf '%s\n' "${!branch_key}")
      git submodule set-branch --branch $branch_value -- $i 
      git submodule update --init --recursive -- $i 

      # checkout commit for submodule
      file_path=$(printf '%s\n' "${i}")
      commit_key=$(echo "${i^^}_COMMIT" | tr - _ )
      commit_value=$(printf '%s\n' "${!commit_key}")
      # todo: how to resolve conflicts? make the submodule return to un-init status first?
      cd `pwd`/$file_path && git pull $remote_url_value $branch_value && git checkout $commit_value && cd ..
   done
}
