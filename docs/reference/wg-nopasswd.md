# WireGuard without a password

Pull and push bring `wg0` up if it is down. Captain Rocket cannot type a sudo password, so the operator group is allowed those two commands only.

| File | Rule |
|------|------|
| `/etc/sudoers.d/stardust-wg` | `%www-admin ALL=(root) NOPASSWD: /usr/bin/wg, /usr/bin/wg-quick` |

`www-admin` is the file group. `deploy` is nologin and is not in this rule. A tunnel that was already up is reused and left up. A tunnel this process started is stopped when the command ends.
