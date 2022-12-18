# sshauth: ssh-key management and user creation system

`sshauth` is a one-bash-script authentication system. `sshauth` has a
daemonless-server-client model that uses the openssh's
`AuthorizedKeysCommand` for client authentication and user creation.

`sshauth` has minimal requirements for system configurations: it
requires the creation of a dedicated user ("sshauth"), an entry in
sudoers (permission to create users), and an entry in sshd_config
(specifying how to query credentials from the server).

All internal sshauth configurations are managed through an admin
repository. Adding a user key and a client node is as simple as
changing a text file, committing changes and pushing them. The
[gitolite](https://gitolite.com/gitolite/index.html) configurations
inspire this approach.

## Usage

If a user has its public key registered in a server, they may create
an account and log in on any client nodes. For that, one should say

```
> ssh sshauth@node

A user "<username>" has been created!

Please login with the same key and the created username.

```

Note that the `node` should have a configuration with a correct
`IdentityFile` in `.ssh/config`, i.e. **a user is authenticated to
create a user** on any nodes. Then, a user may log in on the node
using its username

```
> ssh <username>@node
```

## Requirements

  * OpenSSH >= 6.1

      + `AuthorizedKeysCommand`
      + `ssh-keygen -a 100 -t ed25519` should work

  * git >= 2.25.1 (the oldest version I have around to test)

  * awk (`gsub` should be a part of it)

  * sudo

  * bash

## Installation

For initial installation, say

```
> ./sshauth.sh install admin_keys server_hostname:22
changed /etc/ssh/sshd_config. please restart sshd!
changed /etc/sudoers: allowed sshauth create users

In case it is a server, you can clone the

  sshauth@server:config.git

with one of the specified administrator keys.

If you want the server to be also a client, add the following key to the
config/client_keys file:
ssh-ed25519 <current_sshauth_client_key> current_node_key
```

where `admin_keys` is a file containing public keys of sshauth admins,
and `server_hostname:22` specifies the name of the server (several
servers separated by a comma). Additional keys and servers can be
provided later through the configuration repository.

The installation performs several steps:

  1. creates the `sshauth` user on a current node

  2. adds the following lines to /etc/ssh/sshd_config

     ```
     # sshauth: authenticate using sshauth server
     AuthorizedKeysCommand /home/sshauth/sshauth.sh client %u %t %k
     AuthorizedKeysCommandUser sshauth
     ```

     allowing to authenticate **existing** users using the credentials
     provided by a server.


  3. creates the following entry in /etc/sudoers

     ```
     ## sshauth's permissions to create users
     sshauth ALL=NOPASSWD: /usr/bin/useradd
     ```

     allowing `sshauth` to create new users

  4. creates a configuration repository with access for keys from
     `admin_keys`

  5. creates an ssh-key for `sshauth` for communicating with the
     server, and prints its public part

Each node can serve a purpose of a server, serving authentication data
to a client, or a client, that communicates with servers.

  * For a server node, it is essential to specify `admin_keys`, for
    they allow to clone and work with the admin repository.

  * For a client, it is crucial to give the correct server nodes.

One may want to run `./sshauth.sh install` again, e.g. to update the
version of the `sshauth.sh` script, or to fix anything that broke.


## Configuration

To configure a server, one needs to clone the admin repository. Assume
that the server has the following ssh config:

```
> cat .ssh/config
...
Host sshauth_server
    HostName <server_hostname>
    PubkeyAuthentication yes
    IdentityFile <path_to_admin_key>
    Port 22
    User sshauth
```

then the admin configuration can be cloned as follows:

```
> git clone sshauth_server:config.git
...
> tree config
.
├── admin_keys
├── client_keys
├── keys
│   ├── README
│   └── user1.pub
└── server_hosts
```

  * `admin_keys` contains keys for access to the admin repository.

  * `client_keys` contains generated by sshauth clients' public keys, e.g.

    ```
    ssh-ed25519 <generated_sshauth_client_public_key> client_node1
    # comment
    ssh-ed25519 <generated_sshauth_client_public_key> client_node2
    ```

  * `keys` directory contains user names and authorized_keys data.

  * `server_hosts` contains a list of server hostnames, e.g.

     ```
     hostname1:22
     hostname2:22
     ```

When several servers exist, it is reasonable to have their
configuration be as different git remotes of a single
repository. Hence, any changes should be pushed to all remotes.

A client attempts to connect to different sshauth servers in turn
unless it gets any positive answer from one of them.

## Uninstall

To undo the changes `sshauth.sh install` did, one may say

```
./sshauth.sh uninstall
```

This will remove the "sshauth" user, remove its home directory
together with the administration repository and remove the entries
from `/etc/ssh/sshd_config` and `/etc/sudoers`.

Note that `sshauth.sh uninstall` will not remove any users that were
created. However, those users may lose access to the node if they
didn't make an entry in their `.ssh/authorized_keys` file.

## Security considerations

  1. one can create a user account or log in to a sshauth node if and
     only if one has a key, a public part of which is registered on
     the sshauth server.

  2. sshauth does not store any user private keys. Each sshauth client
     keeps its private key and uses it to communicate with the sshauth
     server.

  3. `sshauth` user is restricted in privileges to a `~/sshauth.sh`
     command. The script has root:root write permission. The
     `~sshauth` is root-only writable.

  4. Use this at your own risk! ;)
