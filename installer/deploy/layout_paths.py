"""The ONE rule for the folder and data-file names that are written INSIDE data (7.2.0).

The move to the new names (deploy/migrate-layout.sh, deploy/migrate-db-name.sh) and a restore of a backup both have to turn the old folder / data-file names that sit in `.env` and in the settings table of the data file
into the names this server uses now (and a restore has to work in both directions: an old-names backup on a moved server, a moved-server backup on a server that stayed on the old names). Both call THIS file; there is no
second copy of the rule. It is shipped twice, byte for byte (core/layout_paths.py for the bot, deploy/layout_paths.py for the scripts, which run before the new bot is installed); a gate test compares the two.
Plain Python, standard library only: it also runs as a command (`python layout_paths.py env|settings|restore-settings ...`).
"""
import json
import os
import re
import sqlite3
import sys

# every name a layout has held: the folders and the data file before the rename and after it
_INSTALLS = ("/root/ApexQuant", "/root/VardynNode")
_DATAS = ("/root/apexquant-data", "/root/vardynnode-data")
_DBS = ("apexquant.db", "vardynnode.db")

LEGACY = ("/root/ApexQuant", "/root/apexquant-data", "apexquant.db")
NEW = ("/root/VardynNode", "/root/vardynnode-data", "vardynnode.db")


_END = r"(?=/|$|\s|['\"`])"      # a whole path segment: the name is followed by "/", the end, a space or a quote (so /root/ApexQuant-Setup.zip and /root/ApexQuant_old are not the install folder)


def rewrite(text, install, data, db_name):
    """The text with every known folder / data-file name turned into the given ones. Returns (new text, how many places changed). A path that is none of the known names is never touched, and a name only counts as a
    whole path segment (followed by "/", the end, white space or a quote). Two phases (the known names become markers first, the markers become the given names second), so a given name that itself contains a known
    name (a folder under another root) is never rewritten again."""
    out = text
    n = 0
    target_db = data.rstrip("/") + "/" + db_name
    marks = (("\x00DB\x00", target_db), ("\x00DATA\x00", data), ("\x00INSTALL\x00", install))
    for d in _DATAS:
        for b in _DBS:
            old = d + "/" + b
            if old != target_db:
                out, k = re.subn(re.escape(old) + _END, lambda m: marks[0][0], out, flags=re.M)
                n += k
    for d in _DATAS:
        if d != data:
            out, k = re.subn(re.escape(d) + _END, lambda m: marks[1][0], out, flags=re.M)
            n += k
    for i in _INSTALLS:
        if i != install:
            out, k = re.subn(re.escape(i) + _END, lambda m: marks[2][0], out, flags=re.M)
            n += k
    for m, value in marks:
        out = out.replace(m, value)
    return out, n


def rewrite_env(text, install, data, db_name):
    """For the text of a .env: (new text, places changed, warnings). The data file path VARDYNNODE_DB_PATH / APEXQUANT_DB_PATH that names some OTHER place is left as it is and warned about."""
    new, n = rewrite(text, install, data, db_name)
    warnings = []
    target_db = data.rstrip("/") + "/" + db_name
    for line in new.splitlines():
        if line.startswith(("VARDYNNODE_DB_PATH=", "APEXQUANT_DB_PATH=")):
            v = line.split("=", 1)[1].strip().strip("'\"")
            if v and v != target_db:
                warnings.append("The data file path in .env names its own place (%s); it was left as it is." % v)
    return new, n, warnings


def rewrite_settings_file(dbfile, install, data, db_name, dry_run=False, saved_json=None):
    """The settings table (app_settings) of a data file: every value that holds a known name is rewritten. Returns how many values changed (dry_run: how many would). With saved_json the old values are written there
    first ({key: [old, new]}) so a put-back is possible."""
    c = sqlite3.connect(dbfile, timeout=30)
    try:
        try:
            rows = c.execute("SELECT key, value FROM app_settings WHERE value IS NOT NULL").fetchall()
        except sqlite3.Error:
            return 0
        changes = {}
        for k, v in rows:
            if not isinstance(v, str):
                continue
            nv, n = rewrite(v, install, data, db_name)
            if n and nv != v:
                changes[k] = [v, nv]
        if changes and not dry_run:
            if saved_json:
                with open(saved_json, "w") as f:
                    json.dump(changes, f)
            for k, (v, nv) in changes.items():
                c.execute("UPDATE app_settings SET value=? WHERE key=?", (nv, k))
            c.commit()
        return len(changes)
    finally:
        c.close()


def restore_settings(dbfile, saved_json):
    """Put the old values back (the put-back of rewrite_settings_file)."""
    if not os.path.exists(saved_json):
        return 0
    c = sqlite3.connect(dbfile, timeout=30)
    try:
        with open(saved_json) as f:
            changes = json.load(f)
        for k, (v, nv) in changes.items():
            c.execute("UPDATE app_settings SET value=? WHERE key=?", (v, k))
        c.commit()
        return len(changes)
    finally:
        c.close()


def _main(argv):
    if len(argv) >= 6 and argv[1] == "env":
        path, install, data, db_name = argv[2:6]
        with open(path, "r", encoding="utf-8", newline="") as f:
            text = f.read()
        new, n, warnings = rewrite_env(text, install, data, db_name)
        if n:
            tmp = path + ".tmp"
            with open(tmp, "w", encoding="utf-8", newline="") as f:
                f.write(new)
            try:
                os.chmod(tmp, os.stat(path).st_mode & 0o7777)
            except OSError:
                pass
            os.replace(tmp, path)
        for w in warnings:
            sys.stderr.write(w + "\n")
        print(n)
        return 0
    if len(argv) >= 6 and argv[1] == "settings":
        dbfile, install, data, db_name = argv[2:6]
        saved = argv[6] if len(argv) > 6 else None
        print(rewrite_settings_file(dbfile, install, data, db_name, saved_json=saved))
        return 0
    if len(argv) >= 4 and argv[1] == "restore-settings":
        print(restore_settings(argv[2], argv[3]))
        return 0
    sys.stderr.write("usage: layout_paths.py env FILE INSTALL DATA DB | settings DBFILE INSTALL DATA DB [SAVED_JSON] | restore-settings DBFILE SAVED_JSON\n")
    return 2


if __name__ == "__main__":
    sys.exit(_main(sys.argv))
