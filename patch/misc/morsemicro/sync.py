#!/usr/bin/env python3

# Compares a MorseMicro/linux tag against the corresponding gregkh/linux branch
# and downloads the diff as individual .patch files.
#
# Usage: ./sync.py mm/linux-6.12.21/1.16.x
# Compare URL: https://github.com/gregkh/linux/compare/linux-6.12.y...MorseMicro:linux:mm/linux-6.12.21/1.16.x

import os
import re
import sys
import requests

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


def slugify(text):
    """Turn a commit subject into a filename-safe string."""
    text = text.strip().lower()
    text = re.sub(r'[^a-z0-9]+', '-', text)
    return text.strip('-')


def get_gregkh_branch(mm_tag):
    """Extract the gregkh stable branch name from a MorseMicro tag.

    mm/linux-6.12.21/1.16.x -> linux-6.12.y
    """
    m = re.match(r'mm/linux-(\d+\.\d+)\.\d+/', mm_tag)
    if not m:
        sys.exit(f"Cannot parse MorseMicro tag: {mm_tag}")
    return f"linux-{m.group(1)}.y"


def get_kernel_major_minor(mm_tag):
    """Extract kernel major.minor from a MorseMicro tag.

    mm/linux-6.12.21/1.16.x -> 6.12
    """
    m = re.match(r'mm/linux-(\d+\.\d+)\.\d+/', mm_tag)
    if not m:
        sys.exit(f"Cannot parse MorseMicro tag: {mm_tag}")
    return m.group(1)


def main():
    if len(sys.argv) < 2:
        sys.exit("Usage: sync.py <morsemicro-tag>\nExample: sync.py mm/linux-6.12.21/1.16.x")

    mm_tag = sys.argv[1]
    base_branch = get_gregkh_branch(mm_tag)
    kernel_ver = get_kernel_major_minor(mm_tag)
    out_dir = os.path.join(SCRIPT_DIR, kernel_ver)

    print(f"Comparing {base_branch}...MorseMicro:linux:{mm_tag}")

    # Use GitHub compare API to list commits unique to the MorseMicro branch
    api_url = f"https://api.github.com/repos/gregkh/linux/compare/{base_branch}...MorseMicro:linux:{mm_tag}"
    headers = {"Accept": "application/vnd.github+json"}

    # Use token from environment if available (to avoid rate limits)
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"

    resp = requests.get(api_url, headers=headers)
    resp.raise_for_status()
    data = resp.json()

    commits = data.get("commits", [])
    if not commits:
        print("No commits found.")
        return

    print(f"Found {len(commits)} commit(s)")

    os.makedirs(out_dir, exist_ok=True)

    # Clear existing patches in output dir
    for f in os.listdir(out_dir):
        if f.endswith(".patch"):
            os.remove(os.path.join(out_dir, f))

    for i, commit in enumerate(commits, start=1):
        sha = commit["sha"]
        subject = commit["commit"]["message"].split('\n', 1)[0]
        slug = slugify(subject)
        filename = f"{i:04d}-{slug}.patch"
        patch_path = os.path.join(out_dir, filename)

        # Download .patch from GitHub
        patch_url = f"https://github.com/MorseMicro/linux/commit/{sha}.patch"
        print(f"  [{i}/{len(commits)}] {filename}")
        patch_resp = requests.get(patch_url)
        patch_resp.raise_for_status()

        with open(patch_path, "w") as f:
            f.write(patch_resp.text)

    print(f"Done. Patches saved to {out_dir}/")


if __name__ == "__main__":
    main()
