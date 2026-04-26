#!/usr/bin/env python3
import argparse
import getpass
import os
import plistlib
import shutil
import sqlite3
import sys
from pathlib import Path


WHATSAPP_DOMAIN_LIKE = "%whatsapp%WhatsApp%.shared"


def parse_args():
    parser = argparse.ArgumentParser(
        description="Extract WhatsApp shared containers from an iPhone backup."
    )
    parser.add_argument(
        "backup",
        type=Path,
        help="Path to the iPhone backup folder containing Manifest.db and Manifest.plist.",
    )
    parser.add_argument(
        "output",
        type=Path,
        help="Output folder for extracted WhatsApp files.",
    )
    parser.add_argument(
        "--password",
        help="Encrypted backup password. Omit to be prompted locally.",
    )
    parser.add_argument(
        "--domain-like",
        default=WHATSAPP_DOMAIN_LIKE,
        help="Manifest domain LIKE pattern. Default: %(default)s",
    )
    return parser.parse_args()


def load_manifest_plist(backup_dir):
    manifest_plist = backup_dir / "Manifest.plist"
    if not manifest_plist.exists():
        raise FileNotFoundError(f"Missing {manifest_plist}")
    with manifest_plist.open("rb") as handle:
        return plistlib.load(handle)


def is_encrypted(manifest):
    return bool(manifest.get("IsEncrypted") or manifest.get("ManifestKey"))


def manifest_db_path(backup_dir):
    path = backup_dir / "Manifest.db"
    if not path.exists():
        raise FileNotFoundError(f"Missing {path}")
    return path


def ensure_backup_shape(backup_dir):
    manifest_db_path(backup_dir)
    load_manifest_plist(backup_dir)


def print_match_summary(rows):
    domains = sorted({domain for domain, _relative_path in rows})
    print(f"Matched {len(rows)} WhatsApp files across {len(domains)} domain(s).")
    for domain in domains:
        print(f"  {domain}")


def extract_encrypted(backup_dir, output_dir, domain_like, password):
    try:
        from iphone_backup_decrypt import EncryptedBackup
    except ImportError as exc:
        raise RuntimeError(
            "Missing iphone-backup-decrypt. Install with: "
            ".venv/bin/python -m pip install iphone-backup-decrypt"
        ) from exc

    if password is None:
        password = getpass.getpass("Encrypted backup password: ")

    backup = EncryptedBackup(
        backup_directory=str(backup_dir),
        passphrase=password,
    )
    backup.test_decryption()

    with backup.manifest_db_cursor() as cursor:
        cursor.execute(
            """
            SELECT domain, relativePath
            FROM Files
            WHERE domain LIKE ?
              AND flags = 1
            ORDER BY domain, relativePath
            """,
            (domain_like,),
        )
        rows = cursor.fetchall()

    if not rows:
        print(f"No files matched domain LIKE {domain_like!r}.")
        return 0

    print_match_summary(rows)
    return backup.extract_files(
        domain_like=domain_like,
        output_folder=str(output_dir),
        preserve_folders=True,
        domain_subfolders=True,
        incremental=True,
    )


def extract_unencrypted(backup_dir, output_dir, domain_like):
    conn = sqlite3.connect(manifest_db_path(backup_dir))
    try:
        cursor = conn.execute(
            """
            SELECT fileID, domain, relativePath
            FROM Files
            WHERE domain LIKE ?
              AND flags = 1
            ORDER BY domain, relativePath
            """,
            (domain_like,),
        )
        rows = cursor.fetchall()
    finally:
        conn.close()

    if not rows:
        print(f"No files matched domain LIKE {domain_like!r}.")
        return 0

    print_match_summary([(domain, relative_path) for _file_id, domain, relative_path in rows])

    extracted = 0
    for file_id, domain, relative_path in rows:
        source = backup_dir / file_id[:2] / file_id
        if not source.exists():
            print(f"Skipping missing backup file: {source}", file=sys.stderr)
            continue

        destination = output_dir / domain / relative_path
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        extracted += 1

    return extracted


def main():
    args = parse_args()
    backup_dir = args.backup.expanduser().resolve()
    output_dir = args.output.expanduser().resolve()

    ensure_backup_shape(backup_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    manifest = load_manifest_plist(backup_dir)
    if is_encrypted(manifest):
        count = extract_encrypted(
            backup_dir=backup_dir,
            output_dir=output_dir,
            domain_like=args.domain_like,
            password=args.password,
        )
    else:
        count = extract_unencrypted(
            backup_dir=backup_dir,
            output_dir=output_dir,
            domain_like=args.domain_like,
        )

    print(f"Extracted {count} file(s) to {output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
