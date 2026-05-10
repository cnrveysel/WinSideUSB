# GitHub Upload Guide

Before pushing, make sure the GitHub repository root is the project folder:

```text
C:\Path\To\WinSideUSB
```

Do not run a first commit from:

```text
C:\Users\<name>
```

or git may try to include unrelated user files.

## Safe Private Repo Setup

From PowerShell:

```powershell
cd C:\Path\To\WinSideUSB

# Only do this if this folder is not already its own repo.
git init

# This must print the project folder, not a parent user folder.
git rev-parse --show-toplevel

git add .gitignore .gitattributes README.md docs scripts `
  WinSideUSB.sln IddSampleDriver.sln WinSideUSB IddSampleDriver

git status --short
```

Before committing, verify that these are not staged:

```text
x64/
.vs/
*.exe
*.dll
*.pdb
*.cat
*.cer
*.csv
output_test.mp4
*_New.cpp
```

Then:

```powershell
git commit -m "Initial WinSideUSB source drop"
git branch -M main
git remote add origin https://github.com/<your-user>/<your-private-repo>.git
git push -u origin main
```

## GitHub Desktop

If using GitHub Desktop:

1. Choose `Add existing repository`.
2. Select exactly the project folder.
3. Confirm the changed files list does not include unrelated user files.
4. Create the repository as private first.

## Public Repo Warning

Before making the repo public:

- choose a license
- remove or document any bundled third-party binaries
- add third-party notices
- do not imply one-click driver installation until the driver is properly signed
