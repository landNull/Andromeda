# WireGuard without a password

Pull and push bring `wg0` up if it is down. Captain Rocket cannot type a sudo password, so the operator group is allowed those two commands only.

| File | Rule |
|------|------|
| `/etc/sudoers.d/andromeda-wg` | `%www-admin ALL=(root) NOPASSWD: /usr/bin/wg, /usr/bin/wg-quick` |

`www-admin` is the file group. `deploy` is nologin and is not in this rule. A tunnel that was already up is reused and left up. A tunnel this process started is stopped when the command ends.

## Endpoint check

`wg_up` reads `/etc/wireguard/wg0.conf` only when the file is readable by the operator. It does not `sudo grep` the conf. That command is not in the sudoers rule, so it always asked for a password and reported a missing Endpoint even when the line was fine.

If `wg-quick up` itself asks for a password, the sudoers drop-in is missing or the operator is not in `www-admin`. After adding the group: `exec su - $USER`.
