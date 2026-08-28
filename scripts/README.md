# scripts/ — kya hai

Is folder mein **ek** management script hai.

| Script | Kaam |
| --- | --- |
| `vicidial-front-ip.sh` | VICIdial 12 admin IP whitelist (`PORTAL_DYNAMIC`) |

**Poori Roman Urdu documentation (har command, DB, timer, Apache, install steps):**

→ [`docs/SCRIPTS-ROMAN-URDU.md`](../docs/SCRIPTS-ROMAN-URDU.md)

Angrezi: [`docs/FRONT-IP-VALIDATION.md`](../docs/FRONT-IP-VALIDATION.md)

```bash
chmod +x vicidial-front-ip.sh
./vicidial-front-ip.sh status
./vicidial-front-ip.sh sync
./vicidial-front-ip.sh add AAPKA.PUBLIC.IP
./vicidial-front-ip.sh enable-admin
./vicidial-front-ip.sh apache-on          # optional
./vicidial-front-ip.sh install-timer      # timer tootey to
```

**Root** se chalao. Pehle poora dialer: `../install-vicidial12-opensuse.sh install --role express`.
