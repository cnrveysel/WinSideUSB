# GitHub Upload Guide

This workspace currently appears inside a broader git root on the local machine. Before pushing, make sure the GitHub repository root is this folder:

```text
C:\Users\Veysel\source\repos\DuetCloneNew
```

Do not run a first commit from:

```text
C:\Users\Veysel
```

or git may try to include unrelated user files.

## Safe Private Repo Setup

From PowerShell:

```powershell
cd C:\Users\Veysel\source\repos\DuetCloneNew

# Only do this if this folder is not already its own repo.
git init

# This must print C:/Users/Veysel/source/repos/DuetCloneNew.
git rev-parse --show-toplevel

git add .gitignore .gitattributes README.md AGENTS.md CLAUDE.md docs scripts `
  WinSideUSB.sln IddSampleDriver.sln DuetCloneNew IddSampleDriver

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
DuetCloneNew/output_test.mp4
DuetCloneNew/DuetCloneNew_New.cpp
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
2. Select exactly `C:\Users\Veysel\source\repos\DuetCloneNew`.
3. Confirm the changed files list does not include `C:\Users\Veysel` files.
4. Create the repository as private first.

## Public Repo Warning

Before making the repo public:

- choose a license
- remove or document any bundled third-party binaries
- add third-party notices
- do not imply one-click driver installation until the driver is properly signed
