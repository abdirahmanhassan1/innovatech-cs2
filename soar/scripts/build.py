"""Builds the deployment package of the SOAR functions.

Same layout as the package Terraform builds: the Python files and rules.json in the root.
Usage (from the repository root): python3 soar/scripts/build.py build/soar.zip
"""
import os
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILES = {
    "soar_common.py": os.path.join(ROOT, "src", "soar_common.py"),
    "ingest.py": os.path.join(ROOT, "src", "ingest.py"),
    "processor.py": os.path.join(ROOT, "src", "processor.py"),
    "cleanup.py": os.path.join(ROOT, "src", "cleanup.py"),
    "rules.json": os.path.join(ROOT, "rules", "rules.json"),
}


def main(output):
    os.makedirs(os.path.dirname(os.path.abspath(output)), exist_ok=True)
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as package:
        for name, path in FILES.items():
            package.write(path, name)
    print(f"Package written to {output} ({len(FILES)} files)")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "build/soar.zip")
