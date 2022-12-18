#!/bin/bash


function print_help {
    echo "Usage: $0 [command] [option]"
    echo
    echo "Commands:"
    echo
    echo "    install [admin_key_file] [server_hostname1:port,server_hostname2:port]"
    echo
    echo "                            install sshauth (requires sudo rights)"
    echo
    echo "                            for a client the 'admin_key_file' can be dummy, but server should be valid sshauth servers"
    echo "                            for clients it is only possible to change server location by calling install again"
    echo
    echo "                            for a server it is important to specify valid admin_key_file in order to be able "
    echo "                            to further clone the admin repository"
    echo
    echo "                            if existing admin_key_file or non-empty server_hostname argument are provided"
    echo "                            then those values overwrite existing configuration"
    echo
    echo "                            run install without arguments to just update the sshauth.sh script"
    echo
    echo "    uninstall"
    echo
    echo "                            uninstall sshauth (requires sudo rights)"
    echo
    echo "    server [username] [optional:key arguments]"
    echo
    echo "                            Query the username's authorized keys"
    echo
    echo "                            If username=='sshauth' then the optional argument must be provided,"
    echo "                            and in that case the server will search for a username matching the key."
    echo "                            The issued authorisation instructs client to create the user."
    echo "                            The key authentication happens on the client side."
    echo
    echo "                            This command is executed on server by a client ssh call."
    echo
    echo "    client [username] [optional:key arguments]"
    echo
    echo "                            Ask the server for the username's public key."
    echo
    echo "                            If username=='sshauth' then optional arguments must be provided, "
    echo "                            and then the server is asked to much a public key to a username."
    echo
    echo "                            This command is executed by sshd, via AuthorizedKeysCommand."
    echo
    echo "    create_user [username]"
    echo
    echo "                            Create provided username (requires sudo useradd for sshauth)"
    echo
    echo "                            This command is executed by sshauth user"
    echo
    echo "    update_settings"
    echo
    echo "                            Regenerate settings locally for sshauth"
    echo
    echo "                            This command is executed by sshauth user on update in repository"
    echo
}


function _default_client_keys {
    cat <<EOF

# Each line in this file is a key generated by a client during the
# 'sshauth.sh config_client'. Those keys are used to authenticate client
# connecting to servers.

# This file may contain comments starting with '#' and empty lines.

EOF
}


function _default_server_hosts {
    cat <<EOF

# Each line in this file specifies the server locations, where each
# entry has the format:
#
# <hostname>:<port>

# This file may contain comments starting with '#' and empty lines.

EOF
}


function _default_admin_keys {
    cat <<EOF

# Each line in this file specifies the administrators public key that
# have access to this repository.

# This file may contain comments starting with '#' and empty lines.

EOF
}


function _default_keys_README {
    cat <<EOF

Place user authorized_keys in this directory. Each file must have a
filename

  <username>.pub

and the content of each file must be of the same format as the
.ssh/authorized_keys.

EOF
}


function _init_repo {
    if [ -d "config.git" ]
    then
        return 0
    fi

    git init -q --bare config.git
    git init -q _config
    cd _config
    mkdir -p keys
    _default_keys_README > keys/README
    _default_client_keys > client_keys
    _default_server_hosts > server_hosts
    _default_admin_keys > admin_keys
    git add client_keys server_hosts admin_keys keys/README
    git config user.email "server@sshauth"
    git config user.name "sshauth"
    git commit -q -m "initial setup"
    git branch -m main
    git remote add origin ~/config.git
    git push -q origin main
    cd ~

    cat <<EOF > config.git/hooks/post-receive
#!/bin/bash

unset GIT_DIR

~/sshauth.sh update_settings 1> /dev/null
EOF
    chmod 700 config.git/hooks/post-receive

    cat <<EOF

In case it is a server, you can clone the

  sshauth@server:config.git

with one of the specified administrator keys.
EOF
}


function _update_sshconfig {
    [ -f ".ssh/config" ] && rm ".ssh/config"
    if [ -f "hosts" ]
    then
        echo -n "" > "hosts"
    fi

    while IFS="" read -r line || [ -n "${line}" ]
    do
        host=$(echo "${line}" | sed -n 's/\([^\:]*\):\([0-9]*\)/\1/p')
        port=$(echo "${line}" | sed -n 's/\([^\:]*\):\([0-9]*\)/\2/p')

        if [ -z "${host}" ]
        then
            continue
        fi

        if [ -z "${port}" ]
        then
            port=22
        fi

        echo "${host}" >> "hosts"
        cat <<EOF >> ".ssh/config"
Host ${host}
    HostName ${host}
    PubkeyAuthentication yes
    IdentityFile ~/.ssh/id_sshauth
    Port ${port}
    User sshauth

EOF
    done < <(grep -o '^[^#]*' ./_config/server_hosts)

    if [ -f ".ssh/config" ]
    then
        chmod 600 ".ssh/config"
    fi
}


function _parse_keyfile {
    ifn="$1"
    ofn="$2"
    prefix="$3"

    while IFS="" read -r line || [ -n "${line}" ]
    do
        if [ -z "$(echo "${line}" | sed '/^\s*$/d')" ]
        then
            continue
        fi

        echo "${prefix} ${line}" >> "${ofn}"
    done < <(grep -o '^[^#]*' "${ifn}")
}


function _update_authorized_keys {
    if [ -f ".ssh/authorized_keys" ]
    then
        rm ".ssh/authorized_keys"
    fi

    touch ".ssh/authorized_keys"

    _parse_keyfile "./_config/client_keys" ".ssh/authorized_keys" \
                   'command="~/sshauth.sh server $SSH_ORIGINAL_COMMAND",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty'
    _parse_keyfile "./_config/admin_keys" ".ssh/authorized_keys" \
                   'command="git-shell -c \"$SSH_ORIGINAL_COMMAND\"",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty'

    chmod 600 ".ssh/authorized_keys"
}


function _generate_sshauth_keys {
    if [ ! -f ".ssh/id_sshauth" ]
    then
        ssh-keygen -a 100 -t ed25519 -q -N "" -f ".ssh/id_sshauth"
        chmod 600 ".ssh/id_sshauth"
        chmod 600 ".ssh/id_sshauth.pub"
    fi

    cat <<EOF

If you want the server to be also a client, add the following key to the client_keys file:
EOF
    cat ".ssh/id_sshauth.pub"
}


function _update_user_keylookup {
    mkdir -p _keylookup
    find _keylookup -mindepth 1 -delete

    find ~/_config/keys -type f -name '*.pub' -print0 |
        while IFS= read -r -d '' fn
        do
            if ! x=$(ssh-keygen -l -f "${fn}")
            then
                >&2 echo "file $(basename ${fn}) does contain any valid keys."
                continue
            fi

            while IFS="" read -r ofn || [ -n "${ofn}" ]
            do
                if [ -f "${ofn}" ]
                then
                    dfn=$(readlink -f "${ofn}")

                    if [ "${dfn}" != "${fn}" ]
                    then
                        >&2 echo "duplicate keys in $(basename ${dfn}) and $(basename ${fn}). You might want to avoid it!"
                    fi

                    continue
                fi

                ln -s "${fn}" "${ofn}"
            done < <(echo "${x}" | awk '{gsub("/",":",$2); print "_keylookup/"$2}')
        done
}


function _setup_local {
    _init_repo
    mkdir -m 700 -p .ssh logs

    cd _config
    git fetch -q origin
    git reset -q --hard origin/main

    sshauth_home=$(eval echo ~sshauth)

    if [ -s "${sshauth_home}/admin_keys.pub" ]
    then
        _default_admin_keys > admin_keys
        cat "${sshauth_home}/admin_keys.pub" >> admin_keys
        echo -n > "${sshauth_home}/admin_keys.pub"
    fi

    if [ -s "${sshauth_home}/server_hosts" ]
    then
        _default_server_hosts > server_hosts
        cat "${sshauth_home}/server_hosts" >> server_hosts
        echo -n > "${sshauth_home}/server_hosts"
    fi

    git add admin_keys server_hosts
    git commit -q -m "updated keys and hosts on install"
    git push -q origin main

    cd "${sshauth_home}"

    _update_authorized_keys
    _update_sshconfig
    _generate_sshauth_keys
    _update_user_keylookup
}


function _create_user {
    user="$1"

    if ! id "${user}" &> /dev/null
    then
        sudo useradd -m "${user}" &> /dev/null
    fi

    cat <<EOF

A user "${user}" has been created!

Please login with the same key and the created username.

EOF
}


function _set_sshdconfig {
    if ! sudo grep -q 'AuthorizedKeysCommandUser sshauth' /etc/ssh/sshd_config
    then
        cat <<EOF | sudo tee --append /etc/ssh/sshd_config > /dev/null
# sshauth: authenticate using sshauth server
AuthorizedKeysCommand $(eval echo ~sshauth)/sshauth.sh client %u %t %k
AuthorizedKeysCommandUser sshauth
EOF
        echo "changed /etc/ssh/sshd_config. please restart sshd!"
    fi
}


function _unset_sshdconfig {
    if sudo grep -q 'AuthorizedKeysCommandUser sshauth' /etc/ssh/sshd_config
    then
        sudo sed -i '/# sshauth: authenticate/d;/AuthorizedKeysCommand.*sshauth.sh/d;/AuthorizedKeysCommandUser sshauth/d' /etc/ssh/sshd_config
        echo "changed /etc/ssh/sshd_config. removed AuthorizedKeysCommand, please restart sshd!"
    fi
}


function _set_sudoers {
    if ! sudo grep -q 'sshauth ALL=NOPASSWD:' /etc/sudoers
    then
        cat <<EOF | sudo tee --append /etc/sudoers > /dev/null
## sshauth's permissions to create users
sshauth ALL=NOPASSWD: $(which useradd)
EOF
        echo "changed /etc/sudoers: allowed sshauth create users"
    fi
}


function _unset_sudoers {
    if sudo grep -q 'sshauth ALL=NOPASSWD:' /etc/sudoers
    then
        sudo sed -i '/## sshauth.. permissions/d;/sshauth ALL=NOPASSWD:/d' /etc/sudoers
        echo "changed /etc/sudoers: removed sshauth permissions"
    fi
}


function _install {
    adminkey="$1"
    server_hosts="$2"

    if ! sudo -v
    then
        >&2 echo "sudo rights are required!"
        exit 1
    fi

    _create_user sshauth &> /dev/null

    _set_sshdconfig
    _set_sudoers

    sshauth_home=$(eval echo ~sshauth)
    sudo cp sshauth.sh "${sshauth_home}/."

    cat "${adminkey}" 2>/dev/null | \
        sudo -H -u sshauth tee "${sshauth_home}/admin_keys.pub" &> /dev/null

    echo -n "${server_hosts}" | sed 's/,/\n/g' | \
        sudo -H -u sshauth tee "${sshauth_home}/server_hosts" &> /dev/null

    sudo chmod go+rx,go-w "${sshauth_home}" "${sshauth_home}/sshauth.sh"
    sudo -H -u sshauth bash -c "${sshauth_home}/sshauth.sh update_settings"
    sudo chown root:root "${sshauth_home}" "${sshauth_home}/sshauth.sh"
}


function _uninstall {
    _unset_sshdconfig
    _unset_sudoers

    if id sshauth &> /dev/null
    then
        sudo chown sshauth:sshauth "$(eval echo ~sshauth)"
        sudo userdel -r sshauth
    fi
}


function _key_lookup {
    key="$@"

    if ! user=$(echo "${key}" | ssh-keygen -l -f -)
    then
        return 1
    fi

    user=$(echo "${user}" | awk '{gsub("/",":",$2); print "_keylookup/"$2}')
    user=$(readlink -f "${user}")

    if [ ! -f "${user}" ]
    then
        return 1
    fi

    user=$(basename "${user}")
    user=${user%.*}
    echo "${user}"
}


function _server {
    user="$1"
    key="${@:2}"

    echo "time=$(date +%s); call=server; user=${user}; key=${key}" >> logs/sshauth.log

    if [ "sshauth" == "${user}" ]
    then
        if create_user=$(_key_lookup "${key}")
        then
            cat <<EOF
command="~/sshauth.sh create_user ${create_user}",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ${key}
EOF
        fi
        return
    fi

    fn="_config/keys/${user}.pub"
    if [ -f "${fn}" ]
    then
        cat "${fn}"
        return
    fi
}


function _client {
    user="$1"
    key="${@:2}"

    while IFS="" read -r host || [ -n "${host}" ]
    do
        if reply=$(ssh -q -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no "${host}" "${user}" "${key}" 2> /dev/null)
        then
            break
        fi
    done < <(shuf ./hosts)

    echo "time=$(date +%s); call=client; user=${user}; key=${key}; reply=${reply}" >> logs/sshauth.log

    echo "${reply}"
}


function parse_args {
    while [[ $# -gt 0 ]]
    do
        case $1 in
            install)
                shift
                _install "$1" "$2"
                exit
                ;;
            uninstall)
                _uninstall
                exit
                ;;
            server)
                shift
                _server $@
                exit
                ;;
            client)
                shift
                _client $@
                exit
                ;;
            create_user)
                shift
                _create_user $@
                exit
                ;;
            update_settings)
                _setup_local
                exit
                ;;
            *|-h|--help)
                print_help
                exit
                ;;
        esac
    done
}


cd $(dirname $0)

parse_args $@
